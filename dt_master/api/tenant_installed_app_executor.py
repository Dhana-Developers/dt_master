import subprocess
import shlex

import frappe
from frappe.utils import now_datetime

BASE_DIR = "/home/frappe/scripts"
SCRIPTS_BASE_DIR = f"{BASE_DIR}/bin/app/"
SCRIPT_LIB_DIR = f"{BASE_DIR}/lib/"

# ---------------------------------------------------------------------
# APP ACTION DEFINITIONS
# ---------------------------------------------------------------------
APP_ACTIONS = {
    "install": {
        "from_status": ["Pending", "Failed"],
        "script": "install_app.sh",
        "success_status": "Installed",
        "failure_status": "Failed",
    },
    "upgrade": {
        "from_status": ["Installed"],
        "script": "upgrade_app.sh",
        "success_status": "Installed",
        "failure_status": "Failed",
    },
    "downgrade": {
        "from_status": ["Installed"],
        "script": "downgrade_app.sh",
        "success_status": "Installed",
        "failure_status": "Failed",
    },
    "reinstall": {
        "from_status": ["Failed"],
        "script": "reinstall_app.sh",
        "success_status": "Installed",
        "failure_status": "Failed",
    },
    "uninstall": {
        "from_status": ["Installed", "Disabled"],
        "script": "uninstall_app.sh",
        "success_status": "Uninstalled",
        "failure_status": "Failed",
    },
    "remove": {
        "from_status": ["Uninstalled"],
        "script": "remove_app.sh",
        "success_status": "Uninstalled",
        "failure_status": "Failed",
    },
    "check_version": {
        "from_status": ["Installed", "Uninstalled"],
        "script": "check_version.sh",
        "readonly": True,
    },
    "check_app": {
        "from_status": ["Installed", "Uninstalled"],
        "script": "check_app.sh",
        "readonly": True,
    },
}

# ---------------------------------------------------------------------
# ACTION LABELS
# ---------------------------------------------------------------------
ACTION_LABELS = {
    "install": "Install",
    "upgrade": "Upgrade",
    "downgrade": "Downgrade",
    "reinstall": "Reinstall",
    "uninstall": "Uninstall",
    "remove": "Uninstall",
    "check_version": "Check App",
    "check_app": "Check App",
}

# ---------------------------------------------------------------------
# SSH CONFIGURATION
# ---------------------------------------------------------------------
def _get_ssh_config(node):
    if not node.access_verified:
        frappe.throw("Node access not verified")

    return {
        "host": node.ip_address.strip(),
        "user": node.ssh_user,
        "port": node.ssh_port or 22,
    }

# ---------------------------------------------------------------------
# CONTEXT LOADING
# ---------------------------------------------------------------------
def _load_action_context(tenant_name, row_name):
    tenant = frappe.get_doc("Tenant Site", tenant_name)
    app_row = next(r for r in tenant.installed_apps if r.name == row_name)
    node = frappe.get_doc("Infrastructure Node", tenant.node)
    return tenant, app_row, node

# ---------------------------------------------------------------------
# ACTION VALIDATION
# ---------------------------------------------------------------------
def _validate_action(app_row, action):
    action_def = APP_ACTIONS.get(action)
    if not action_def:
        frappe.throw(f"Unknown app action: {action}")

    if app_row.status not in action_def["from_status"]:
        frappe.throw(
            f"Action '{action}' not allowed from status '{app_row.status}'"
        )

    if action not in ACTION_LABELS:
        frappe.throw(f"No UI label defined for action '{action}'")

    return action_def

# ---------------------------------------------------------------------
# ACTION STATE MANAGEMENT
# ---------------------------------------------------------------------
def _mark_action_running(tenant, app_row, action):
    app_row.last_action = ACTION_LABELS[action]
    app_row.last_action_status = "Running"
    app_row.last_error = None
    tenant.save(ignore_permissions=True)
    frappe.db.commit()

# ---------------------------------------------------------------------
# SCRIPT EXECUTION
# ---------------------------------------------------------------------
def _execute_ssh_script(node, tenant, app_row, script_name):
    ssh = _get_ssh_config(node)

    extension_version = None
    extension = None

    if app_row.extension_version:
        extension_version = frappe.get_doc(
            "Extension Version",
            app_row.extension_version
        )
        extension = frappe.get_doc(
            "Extension",
            extension_version.extension
        )

    env = (
        f"export APP_NAME='{app_row.app_name}'; "
        f"export TARGET_VERSION='v{app_row.target_version or ''}'; "

        f"export SCRIPTS_BASE_DIR='{SCRIPTS_BASE_DIR}'; "
        f"export PROJECT_BASE_DIR='{node.project_base_dir}'; "
        f"export PROJECT_LOGS_DIR='{node.project_logs_dir}'; "
        f"export BENCH_DIR='{node.project_base_dir}/bench'; "
        f"export SCRIPT_LIB_DIR='{SCRIPT_LIB_DIR}'; "
        f"export BASE_DIR='{BASE_DIR}'; "

        f"export SITE_NAME='{tenant.fqdn}'; "
        f"export DB_NAME='{tenant.database_name}'; "
        f"export ADMIN_PASSWORD='{tenant.admin_password}'; "
        f"export MYSQL_ROOT_USER='{tenant.mysql_root_user_name}'; "
        f"export MYSQL_ROOT_PASSWORD='{tenant.mysql_root_user_password}'; "
        f"export FRAPPE_UPSTREAM_PORT='{tenant.port}'; "
        f"export FRAPPE_VERSION='{node.frappe_version}'; "

        f"export INSTALL_MODE='{extension.install_mode if extension else ''}'; "
        f"export SOURCE_REF='{extension_version.source_ref if extension_version else ''}'; "
        f"export REF_TYPE='{extension_version.ref_type if extension_version else ''}'; "
        f"export REPOSITORY_URL='{extension.repository_url if extension else ''}'; "
        f"export FRAPPE_HOME='/home/frappe'; "
    )

    remote_cmd = f"{env} bash {SCRIPTS_BASE_DIR}{script_name}"

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

# ---------------------------------------------------------------------
# EXECUTION WRAPPER
# ---------------------------------------------------------------------
def _execute_action(node, tenant, app_row, script):
    exit_code, stdout, stderr = _execute_ssh_script(
        node, tenant, app_row, script
    )

    error = None
    if exit_code != 0:
        error = _extract_error(stdout, stderr, exit_code)

    return {
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "error": error,
    }

# ---------------------------------------------------------------------
# OUTPUT PARSING
# ---------------------------------------------------------------------
def _parse_kv_output(stdout: str) -> dict:
    data = {}
    for line in stdout.splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data

# ---------------------------------------------------------------------
# ERROR EXTRACTION
# ---------------------------------------------------------------------
def _extract_error(stdout, stderr, exit_code):
    if stderr:
        return stderr.strip().splitlines()[-1]
    if stdout:
        return stdout.strip().splitlines()[-1]
    return f"Exited with code {exit_code}"

# ---------------------------------------------------------------------
# EXTENSION RETRIEVAL/CREATION
# ---------------------------------------------------------------------
def get_or_create_extension(parsed):
    app_name = parsed["app_name"]

    name = frappe.db.get_value(
        "Extension",
        {"app_name": app_name},
        "name"
    )

    if name:
        return frappe.get_doc("Extension", name)

    extension = frappe.get_doc({
        "doctype": "Extension",
        "extension_name": app_name,
        "app_name": app_name,
        "repository_url": parsed.get("repository_url"),
        "install_mode": parsed.get("install_mode"),
        "default_branch": parsed.get("git_branch"),
        "status": "Approved",
    })
    extension.insert(ignore_permissions=True)

    return extension

# ---------------------------------------------------------------------
# MAJOR VERSION EXTRACTION
# ---------------------------------------------------------------------
def extract_major_versions(parsed: dict) -> set[int]:
    majors = set()

    for key in (
        "installed_version",
        "next_major_version",
        "latest_major_version",
    ):
        val = parsed.get(key)
        if val:
            try:
                majors.add(int(val.split(".", 1)[0]))
            except ValueError:
                pass

    return majors

# ---------------------------------------------------------------------
# EXTENSION VERSION RECONCILIATION
# ---------------------------------------------------------------------
def reconcile_extension_major_versions(extension, parsed):
    majors = extract_major_versions(parsed)
    created_or_found = []

    ref_type = parsed.get("ref_type")
    source_ref = parsed.get("source_ref") or parsed.get("git_ref")

    install_strategy = (
        "git_branch" if ref_type == "branch"
        else "git_tag" if ref_type == "tag"
        else "git_commit"
    )

    for major in sorted(majors):
        name = f"{extension.name}-v{major}.*"

        if frappe.db.exists("Extension Version", name):
            ev = frappe.get_doc("Extension Version", name)
            created_or_found.append(ev)
            continue

        ev = frappe.get_doc({
            "doctype": "Extension Version",
            "name": name,
            "extension": extension.name,
            "version": f"v{major}.*",
            "frappe_min": f"{major}.0.0",
            "frappe_max": f"{major}.999.999",
            "release_notes": f"Frappe Version {major}",
            "deprecated": 0,
            "source_ref": f"version-{major}",
            "ref_type": ref_type,
            "install_strategy": install_strategy,
            "status": "Approved",
        })

        ev.insert(ignore_permissions=True)
        created_or_found.append(ev)

    return created_or_found

# ---------------------------------------------------------------------
# RESULT HANDLERS
# ---------------------------------------------------------------------
def _handle_readonly_result(tenant, app_row, result, action):
    app_row.last_action_status = (
        "Success" if result["exit_code"] == 0 else "Failed"
    )
    app_row.last_error = result["error"]

    if result["exit_code"] != 0:
        tenant.save(ignore_permissions=True)
        frappe.db.commit()
        raise frappe.ValidationError(result["error"])

    parsed = _parse_kv_output(result["stdout"])
    if action == "check_version":
        extension = get_or_create_extension(parsed)
        extension_versions = reconcile_extension_major_versions(extension, parsed)
        app_row.target_version = parsed.get("latest_minor_version") or app_row.target_version
    app_row.status = (
        "Installed" if parsed.get("installed") == "true" else "Uninstalled"
    )
    app_row.installed_version = (
        parsed.get("installed_version") or app_row.installed_version
    )
    app_row.git_branch = parsed.get("git_branch")
    app_row.git_commit = parsed.get("git_commit")
    app_row.git_dirty = parsed.get("dirty") == "true"
    app_row.git_head_state = parsed.get("git_head_state")

    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    return parsed

def _handle_mutating_result(tenant, app_row, action_def, result):
    if result["exit_code"] == 0:
        app_row.status = action_def["success_status"]
        app_row.installed_version = (
            app_row.target_version or app_row.installed_version
        )
        app_row.installed_at = now_datetime()
        app_row.last_action_status = "Success"
        app_row.last_error = None
    else:
        app_row.status = action_def["failure_status"]
        app_row.last_action_status = "Failed"
        app_row.last_error = result["error"]
    parsed = _parse_kv_output(result["stdout"])
    app_row.target_version = parsed.get("latest_minor_version") or app_row.target_version
    app_row.status = (
        "Installed" if parsed.get("installed") == "true" else "Uninstalled"
    )
    app_row.installed_version = (
        parsed.get("installed_version") or app_row.installed_version
    )
    app_row.git_branch = parsed.get("git_branch")
    app_row.git_commit = parsed.get("git_commit")
    app_row.git_dirty = parsed.get("dirty") == "true"
    app_row.git_head_state = parsed.get("git_head_state")
    app_row.last_updated = now_datetime()
    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    if result["exit_code"] != 0:
        raise frappe.ValidationError(result["error"])

    return result["stdout"]

# ---------------------------------------------------------------------
# MAIN ORCHESTRATOR
# ---------------------------------------------------------------------
def _run_app_action(tenant_name, row_name, action):
    tenant, app_row, node = _load_action_context(tenant_name, row_name)
    action_def = _validate_action(app_row, action)

    _mark_action_running(tenant, app_row, action)

    result = _execute_action(
        node, tenant, app_row, action_def["script"]
    )
    print(result)
    if action_def.get("readonly"):
        return _handle_readonly_result(tenant, app_row, result,action)

    return _handle_mutating_result(tenant, app_row, action_def, result)

# ---------------------------------------------------------------------
# FRAPPE WHITELISTED FUNCTIONS
# ---------------------------------------------------------------------
@frappe.whitelist()
def install_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "install")

@frappe.whitelist()
def upgrade_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "upgrade")

@frappe.whitelist()
def downgrade_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "downgrade")

@frappe.whitelist()
def reinstall_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "install")

@frappe.whitelist()
def uninstall_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "uninstall")

@frappe.whitelist()
def remove_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "remove")

@frappe.whitelist()
def check_version(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "check_version")

@frappe.whitelist()
def check_app(tenant_name, row_name):
    return _run_app_action(tenant_name, row_name, "check_app")
