import subprocess
import shlex

import frappe
from frappe.utils import now_datetime

# ---------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------

BASE_DIR = "/home/frappe/scripts"
SCRIPTS_BASE_DIR = f"{BASE_DIR}/bin/site/"
SCRIPT_LIB_DIR = f"{BASE_DIR}/lib/"

# ---------------------------------------------------------------------
# STATE MACHINES
# ---------------------------------------------------------------------

ALLOWED_AUTOMATION_TRANSITIONS = {
    "idle": ["idle", "queued", "resuming"],
    "queued": ["creating_site", "installing_apps", "suspending", "resuming", "destroying"],
    "creating_site": ["installing_apps", "failed", "queued"],
    "installing_apps": ["failed", "ready", "queued"],
    "verifying": ["verifying"],
    "suspending": ["idle", "failed", "queued"],
    "resuming": ["ready", "failed", "queued"],
    "destroying": ["destroyed", "failed", "queued"],
    "ready": ["verifying", "suspending", "destroying", "queued"],
    "suspended": ["verifying", "resuming", "destroying", "queued"],
    "destroyed": [],
    "failed": ["queued", "creating_site", "installing_apps", "suspending", "resuming", "destroying"],
}

TENANT_SITE_TRANSITIONS = {
    "create_site": {
        "from": ["idle", "failed"],
        "to": "creating_site",
        "success": ("installing_apps", "Provisioning"),
        "failure": ("failed", "Provisioning"),
    },
    "install_apps": {
        "from": ["creating_site"],
        "to": None,
        "success": None,
        "failure": None,
    },
    "verify_site": {
        "from": ["idle", "creating_site", "installing_apps", "ready", "suspended", "failed"],
        "to": None,
        "success": None,
        "failure": None,
    },
    "suspend_site": {
        "from": ["ready"],
        "to": "suspending",
        "success": ("idle", "Suspended"),
        "failure": ("failed", "Active"),
    },
    "resume_site": {
        "from": ["suspended"],
        "to": "resuming",
        "success": ("ready", "Active"),
        "failure": ("failed", "Suspended"),
    },
    "destroy_site": {
        "from": ["ready", "suspended"],
        "to": "destroying",
        "success": ("archived", "Archived"),
        "failure": ("failed", "Archived"),
    },
    "configure_proxy": {
        "from": ["ready", "suspended", "failed"],
        "to": None,
        "success": None,
        "failure": None,
    },
}

ALLOWED_STATUS_TRANSITIONS = {
    "Requested": ["Provisioning", "Archived"],
    "Provisioning": ["Active", "Archived"],
    "Active": ["Suspended", "Archived"],
    "Suspended": ["Active", "Archived"],
    "Archived": [],
}

ACTION_SCRIPT_MAP = {
    "create_site": ("creating_site", "create_site.sh"),
    "install_apps": ("installing_apps", "install_apps.sh"),
    "verify_site": ("verifying", "verify_site.sh"),
    "suspend_site": ("idle", "suspend_site.sh"),
    "resume_site": ("resuming", "resume_site.sh"),
    "destroy_site": ("destroying", "destroy_site.sh"),
    "configure_proxy":("configuring_proxy", "configure_tenant_proxy.sh"),
}

MAINTENANCE_ACTIONS = {"install_apps", "configure_proxy"}

# ---------------------------------------------------------------------
# SSH + EXECUTION
# ---------------------------------------------------------------------

def _get_ssh_config(node):
    if not node.project_base_dir or not node.project_logs_dir:
        frappe.throw("Project paths not configured on node")
    if not node.access_verified:
        frappe.throw("Node access not verified")
    if not node.ip_address or not node.ssh_user:
        frappe.throw("Incomplete SSH configuration")

    return {
        "host": node.ip_address.strip(),
        "user": node.ssh_user,
        "port": node.ssh_port or 22,
    }


def _execute_ssh_script(node, tenant, script_name, apps=None):
    ssh = _get_ssh_config(node)

    env_exports = (
        f"export SCRIPTS_BASE_DIR='{SCRIPTS_BASE_DIR}'; "
        f"export PROJECT_BASE_DIR='{node.project_base_dir}'; "
        f"export PROJECT_LOGS_DIR='{node.project_logs_dir}'; "
        f"export BENCH_DIR='{node.project_base_dir}/bench'; "
        f"export SITE_NAME='{tenant.fqdn}'; "
        f"export DB_NAME='{tenant.database_name}'; "
        f"export ADMIN_PASSWORD='{tenant.admin_password}'; "
        f"export MYSQL_ROOT_USER='{tenant.mysql_root_user_name}'; "
        f"export MYSQL_ROOT_PASSWORD='{tenant.mysql_root_user_password}'; "
        f"export FRAPPE_UPSTREAM_PORT='{tenant.port}'; "
        f"export FRAPPE_VERSION='{node.frappe_version}'; "
        f"export SCRIPT_LIB_DIR='{SCRIPT_LIB_DIR}'; "
        f"export BASE_DIR='{BASE_DIR}'; "
        f"export TENANT_PROTOCOL='{tenant.protocol}'; "
        f"export LOCAL_HOSTS_ENTRY='{"true" if tenant.protocol == 'http' else "false"}'; "
    )
    print(apps)
    if apps:
        env_exports += f"export APPS='{','.join(apps)}'; "

    remote_cmd = f"{env_exports} bash {SCRIPTS_BASE_DIR}{script_name}"

    ssh_command = (
        f"ssh -p {ssh['port']} "
        f"{ssh['user']}@{ssh['host']} "
        f"{shlex.quote(remote_cmd)}"
    )

    proc = subprocess.Popen(
        ssh_command,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    stdout, stderr = proc.communicate()
    return proc.returncode, stdout, stderr


def _extract_meaningful_error(stdout, stderr, exit_code):
    stderr = (stderr or "").strip()
    stdout = (stdout or "").strip()

    if stderr:
        lines = [l for l in stderr.splitlines() if l.strip()]
        return lines[-1]
    if stdout:
        lines = [l for l in stdout.splitlines() if l.strip()]
        return lines[-1]
    return f"Command failed with exit code {exit_code}"


def _execute_action(node, tenant, script_name, apps=None):
    exit_code, stdout, stderr = _execute_ssh_script(
        node=node,
        tenant=tenant,
        script_name=script_name,
        apps=apps,
    )

    error = None
    if exit_code != 0:
        error = _extract_meaningful_error(stdout, stderr, exit_code)

    return exit_code, stdout, stderr, error

# ---------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------

def _log_tenant_action(
    tenant,
    action_name,
    automation_before,
    automation_after,
    result,
    exit_code,
    stdout,
    stderr,
    started_at,
    finished_at,
):
    tenant.append("automation_logs", {
        "action_name": action_name,
        "triggered_by": frappe.session.user,
        "started_at": started_at,
        "finished_at": finished_at,
        "duration_seconds": (finished_at - started_at).total_seconds(),
        "state_before": automation_before,
        "state_after": automation_after,
        "status": tenant.status,
        "result": result,
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr,
    })
    tenant.save(ignore_permissions=True)
    frappe.db.commit()

# ---------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------

def _validate_transition(*, from_state, to_state, from_status=None, to_status=None):
    if to_state and from_state != to_state:
        if to_state not in ALLOWED_AUTOMATION_TRANSITIONS.get(from_state, []):
            frappe.throw(f"Invalid automation_state transition: {from_state} → {to_state}")

    if to_status and from_status and from_status != to_status:
        if to_status not in ALLOWED_STATUS_TRANSITIONS.get(from_status, []):
            frappe.throw(f"Invalid status transition: {from_status} → {to_status}")


def _is_maintenance_action(action, tenant):
    return (
        action in MAINTENANCE_ACTIONS
        and tenant.automation_state == "ready"
        and tenant.status == "Active"
    )

# ---------------------------------------------------------------------
# SPECIALIZED RUNNERS
# ---------------------------------------------------------------------

def _run_maintenance_action(tenant, node, apps, script_name, state_before, action):
    started_at = now_datetime()

    exit_code, stdout, stderr, error = _execute_action(
        node, tenant, script_name, apps
    )

    finished_at = now_datetime()
    result = "Success" if exit_code == 0 else "Failed"

    for row in tenant.installed_apps:
        if row.app_name in apps:
            row.status = "Installed" if exit_code == 0 else "Failed"
            row.last_error = error
            row.last_updated = now_datetime()
            if exit_code == 0:
                row.installed_at = now_datetime()

    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    _log_tenant_action(
        tenant,
        action.replace("_", " ").title(),
        state_before,
        state_before,
        result,
        exit_code,
        stdout,
        error,
        started_at,
        finished_at,
    )

    if exit_code != 0:
        raise frappe.ValidationError(error)

    return stdout


def _run_readonly_action(tenant, node, action, script_name, state_before,apps):
    started_at = now_datetime()

    exit_code, stdout, stderr, error = _execute_action(
        node, tenant, script_name,apps
    )

    finished_at = now_datetime()
    result = "Success" if exit_code == 0 else "Failed"

    _log_tenant_action(
        tenant,
        action.replace("_", " ").title(),
        state_before,
        state_before,
        result,
        exit_code,
        stdout,
        error,
        started_at,
        finished_at,
    )

    if exit_code != 0:
        raise frappe.ValidationError(error)

    return stdout


def _resolve_lifecycle_outcome(tenant, action, apps, transition, exit_code, error):
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"

        if action == "install_apps":
            for row in tenant.installed_apps:
                if row.app_name in apps:
                    row.status = "Installed"
                    row.last_error = None
                    row.installed_at = now_datetime()
                    row.last_updated = now_datetime()
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

        if action == "install_apps":
            for row in tenant.installed_apps:
                if row.app_name in apps:
                    row.status = "Failed"
                    row.last_error = error
                    row.last_updated = now_datetime()

    return next_state, next_status, result

# ---------------------------------------------------------------------
# MAIN ENTRY
# ---------------------------------------------------------------------

def _run_tenant_action(tenant_name, action):
    transition = TENANT_SITE_TRANSITIONS.get(action)
    if not transition:
        frappe.throw(f"Unknown tenant action: {action}")

    tenant = frappe.get_doc("Tenant Site", tenant_name)
    node = frappe.get_doc("Infrastructure Node", tenant.node)

    state_before = tenant.automation_state or "idle"
    status_before = tenant.status

    target_state, script_name = ACTION_SCRIPT_MAP[action]

    apps = []
    if action == "install_apps":
        apps = [
            r.app_name for r in tenant.installed_apps
            if r.enabled and r.status in ("Pending", "Failed")
        ]
        if not apps:
            frappe.throw("No pending apps to install")

    # Maintenance
    if _is_maintenance_action(action, tenant):
        return _run_maintenance_action(
            tenant, node, apps, script_name, state_before, action
        )

    # Read-only
    if transition["to"] is None:
        return _run_readonly_action(
            tenant, node, action, script_name, state_before,apps
        )

    # Lifecycle
    started_at = now_datetime()

    if tenant.automation_state != "queued":
        _validate_transition(
            from_state=tenant.automation_state,
            to_state="queued",
            from_status=status_before,
            to_status=status_before,
        )
        tenant.automation_state = "queued"
        tenant.save(ignore_permissions=True)
        frappe.db.commit()

    _validate_transition(
        from_state="queued",
        to_state=transition["to"],
        from_status=status_before,
        to_status=status_before,
    )

    tenant.automation_state = transition["to"]
    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    exit_code, stdout, stderr, error = _execute_action(
        node, tenant, script_name, apps
    )

    finished_at = now_datetime()

    next_state, next_status, result = _resolve_lifecycle_outcome(
        tenant, action, apps, transition, exit_code, error
    )

    _validate_transition(
        from_state=tenant.automation_state,
        to_state=next_state,
        from_status=status_before,
        to_status=next_status,
    )

    tenant.automation_state = next_state
    tenant.status = next_status
    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    _log_tenant_action(
        tenant,
        action.replace("_", " ").title(),
        state_before,
        tenant.automation_state,
        result,
        exit_code,
        stdout,
        error,
        started_at,
        finished_at,
    )

    if exit_code != 0:
        raise frappe.ValidationError(error)

    return stdout

# ---------------------------------------------------------------------
# WHITELISTED APIS
# ---------------------------------------------------------------------

@frappe.whitelist()
def create_site(tenant_name): return _run_tenant_action(tenant_name, "create_site")

@frappe.whitelist()
def install_apps(tenant_name): return _run_tenant_action(tenant_name, "install_apps")

@frappe.whitelist()
def verify_site(tenant_name): return _run_tenant_action(tenant_name, "verify_site")

@frappe.whitelist()
def suspend_site(tenant_name): return _run_tenant_action(tenant_name, "suspend_site")

@frappe.whitelist()
def resume_site(tenant_name): return _run_tenant_action(tenant_name, "resume_site")

@frappe.whitelist()
def destroy_site(tenant_name): return _run_tenant_action(tenant_name, "destroy_site")

@frappe.whitelist()
def configure_proxy(tenant_name):return _run_tenant_action(tenant_name, "configure_proxy")
