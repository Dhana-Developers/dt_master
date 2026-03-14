import frappe
import shlex
import subprocess
from frappe.utils import now_datetime


BASE_DIR = "/home/frappe/scripts"
SCRIPTS_BASE_DIR = f"{BASE_DIR}/bin/mail"
SCRIPT_LIB_DIR = f"{BASE_DIR}/lib"


MAIL_AUTOMATION_TRANSITIONS = {
    "idle": ["idle", "queued", "installing_stack"],
    
    "queued": [
        "installing_stack",
        "configuring_postfix",
        "configuring_dovecot",
        "configuring_rspamd",
        "configuring_opendkim",
        "configuring_dns",
        "verifying",
        "destroying",
        "failed"
    ],

    "installing_stack": ["configuring_postfix", "failed", "queued"],
    
    "configuring_postfix": ["configuring_dovecot", "failed", "queued"],
    
    "configuring_dovecot": ["configuring_rspamd", "failed", "queued"],
    
    "configuring_rspamd": ["configuring_opendkim", "failed", "queued"],
    
    "configuring_opendkim": ["configuring_dns", "failed", "queued"],
    
    "configuring_dns": ["verifying", "failed", "queued"],
    
    "verifying": ["ready", "failed", "queued"],
    
    "ready": ["verifying", "destroying", "queued"],
    
    "destroying": ["destroyed", "failed"],
    
    "destroyed": [],
    
    "failed": [
        "queued",
        "installing_stack",
        "configuring_postfix",
        "configuring_dovecot",
        "configuring_rspamd",
        "configuring_opendkim",
        "configuring_dns",
        "verifying"
    ],
}

MAIL_STATUS_TRANSITIONS = {
    "Requested": ["Installing", "Archived"],
    "Installing": ["Active", "Failed", "Archived"],
    "Active": ["Installing", "Archived"],
    "Failed": ["Installing", "Archived"],
    "Archived": [],
}

MAIL_SERVER_TRANSITIONS = {

    "install_stack": {
        "from": ["idle", "failed"],
        "to": "installing_stack",
        "success": ("configuring_postfix", "Installing"),
        "failure": ("failed", "Failed"),
    },

    "configure_postfix": {
        "from": ["installing_stack"],
        "to": "configuring_postfix",
        "success": ("configuring_dovecot", "Installing"),
        "failure": ("failed", "Failed"),
    },

    "configure_dovecot": {
        "from": ["configuring_postfix"],
        "to": "configuring_dovecot",
        "success": ("configuring_rspamd", "Installing"),
        "failure": ("failed", "Failed"),
    },

    "configure_rspamd": {
        "from": ["configuring_dovecot"],
        "to": "configuring_rspamd",
        "success": ("configuring_opendkim", "Installing"),
        "failure": ("failed", "Failed"),
    },

    "configure_opendkim": {
        "from": ["configuring_rspamd"],
        "to": "configuring_opendkim",
        "success": ("configuring_dns", "Installing"),
        "failure": ("failed", "Failed"),
    },

    "configure_dns": {
        "from": ["configuring_opendkim"],
        "to": "configuring_dns",
        "success": ("verifying", "Installing"),
        "failure": ("failed", "Failed"),
    },

    "verify_mail": {
        "from": ["verifying", "configuring_dns", "failed"],
        "to": "verifying",
        "success": ("ready", "Active"),
        "failure": ("failed", "Failed"),
    },

    "destroy_mail": {
        "from": ["ready", "failed"],
        "to": "destroying",
        "success": ("destroyed", "Archived"),
        "failure": ("failed", "Archived"),
    },
}

MAIL_SERVER_TRANSITIONS.update({

    "add_user": {
        "from": ["ready"],
        "to": "ready",
        "success": ("ready", "Active"),
        "failure": ("ready", "Active"),
    },

    "remove_user": {
        "from": ["ready"],
        "to": "ready",
        "success": ("ready", "Active"),
        "failure": ("ready", "Active"),
    },

})

MAIL_SERVER_TRANSITIONS.update({

    "list_users": {
        "from": ["ready"],
        "to": "ready",
        "success": ("ready", "Active"),
        "failure": ("ready", "Active"),
    },

})

MAIL_SERVER_TRANSITIONS.update({

    "update_user_password": {
        "from": ["ready"],
        "to": "ready",
        "success": ("ready", "Active"),
        "failure": ("ready", "Active"),
    },

})

MAIL_ACTION_SCRIPT_MAP = {
    "install_stack": ("installing_stack", "install_mail_stack.sh"),
    "configure_postfix": ("configuring_postfix", "configure_postfix.sh"),
    "configure_dovecot": ("configuring_dovecot", "configure_dovecot.sh"),
    "configure_rspamd": ("configuring_rspamd", "configure_rspamd.sh"),
    "configure_opendkim": ("configuring_opendkim", "configure_opendkim.sh"),
    "configure_dns": ("configuring_dns", "configure_dns_records.sh"),
    "verify_mail": ("verifying", "verify_mail_server.sh"),
}

MAIL_ACTION_SCRIPT_MAP.update({
    "add_user": ("ready", "add_user.sh"),
    "remove_user": ("ready", "remove_user.sh"),
})
MAIL_ACTION_SCRIPT_MAP.update({
    "list_users": ("ready", "list_users.sh"),
})

MAIL_ACTION_SCRIPT_MAP.update({
    "update_user_password": ("ready", "update_user_password.sh"),
})




# -----------------------------------------------------------
# SSH CONFIG
# -----------------------------------------------------------

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


# -----------------------------------------------------------
# SCRIPT EXECUTION
# -----------------------------------------------------------

def _execute_mail_script(node, mail_server, script_name, mail_user=None):

    ssh = _get_ssh_config(node)

    if not node.scripts_base_dir:
        frappe.throw("Scripts base directory not configured on node")

    if not node.ip_address:
        frappe.throw("Node IP address not configured")

    tenant = None
    if mail_server.tenant_site:
        tenant = frappe.get_doc("Tenant Site", mail_server.tenant_site)

    SCRIPT_BASE_DIR = f"{node.scripts_base_dir}/bin/mail"
    SCRIPT_LIB_DIR = f"{node.scripts_base_dir}/lib"

    env_exports = (
        f"export SCRIPTS_BASE_DIR='{SCRIPT_BASE_DIR}'; "
        f"export SCRIPT_LIB_DIR='{SCRIPT_LIB_DIR}'; "
        f"export BASE_DIR='{BASE_DIR}'; "

        f"export MAIL_DOMAIN='{mail_server.domain}'; "
        f"export MAIL_HOSTNAME='{mail_server.hostname}'; "
        f"export MAIL_IP='{node.ip_address}'; "

        f"export SMTP_PORT='{mail_server.smtp_port}'; "
        f"export IMAP_PORT='{mail_server.imap_port}'; "
        f"export DKIM_SELECTOR='{mail_server.dkim_selector}'; "

        f"export PROJECT_BASE_DIR='{node.project_base_dir}'; "
        f"export PROJECT_LOGS_DIR='{node.project_logs_dir}'; "
    )

    # -------------------------------------------------
    # Tenant variables (optional)
    # -------------------------------------------------
    if tenant:

        env_exports += (
            f"export SITE_NAME='{tenant.fqdn}'; "
            f"export TENANT_PROTOCOL='{tenant.protocol or 'https'}'; "
            f"export FRAPPE_UPSTREAM_PORT='{tenant.port or ''}'; "
            f"export DB_NAME='{tenant.database_name or ''}'; "
            f"export ADMIN_PASSWORD='{tenant.admin_password or ''}'; "
            f"export MYSQL_ROOT_USER='{tenant.mysql_root_user_name or ''}'; "
            f"export MYSQL_ROOT_PASSWORD='{tenant.mysql_root_user_password or ''}'; "
        )

        if mail_user:

            local, domain = mail_user.email.split("@")

            env_exports += f"export MAIL_USER='{local}'; "

            if mail_user.password:
                env_exports += f"export MAIL_PASSWORD='{mail_user.get_password('password')}'; "

    remote_cmd = (
        f"sudo -n bash -c "
        f"{shlex.quote(env_exports + f'bash {SCRIPT_BASE_DIR}/{script_name}')}"
    )

    ssh_command = (
        f"ssh -p {ssh['port']} "
        f"{ssh['user']}@{ssh['host']} "
        f"{shlex.quote(remote_cmd)}"
    )

    proc = subprocess.Popen(
        ssh_command,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )

    output_lines = []

    for line in iter(proc.stdout.readline, ''):
        line = line.rstrip()
        output_lines.append(line)
        print(line)

        # optional streaming point
        # frappe.publish_realtime("mail_executor_log", {
        #     "server": mail_server.name,
        #     "line": line
        # })

    proc.wait()

    stdout = "\n".join(output_lines)

    return proc.returncode, stdout, ""


# -----------------------------------------------------------
# ERROR EXTRACTION
# -----------------------------------------------------------

def _extract_error(stdout, stderr, exit_code):

    stderr = (stderr or "").strip()
    stdout = (stdout or "").strip()

    if stderr:
        return stderr.splitlines()[-1]

    if stdout:
        return stdout.splitlines()[-1]

    return f"Command failed with exit code {exit_code}"

def _log_mail_action(
    mail_server,
    action_name,
    result,
    exit_code,
    stdout,
    stderr,
    started_at,
    finished_at,
):

    mail_server.append("automation_logs", {
    "action_name": action_name,
    "triggered_by": frappe.session.user,
    "started_at": started_at,
    "finished_at": finished_at,
    "duration_seconds": (finished_at - started_at).total_seconds(),
    "result": result,
    "exit_code": exit_code,
    "stdout": stdout,
    "stderr": stderr,
})

    mail_server.save(ignore_permissions=True)
    frappe.db.commit()


def generate_system_username(email):
    local, domain = email.split("@")
    return f"{local}_{domain.replace('.', '_')}"

# -----------------------------------------------------------
# MAIN ACTION RUNNER
# -----------------------------------------------------------
def _run_mail_action(mail_server_name, action, mail_user=None):

    mapping = MAIL_ACTION_SCRIPT_MAP.get(action)

    if not mapping:
        frappe.throw(f"Unknown mail action: {action}")

    expected_state, script = mapping

    mail_server = frappe.get_doc("Mail Server", mail_server_name)
    node = frappe.get_doc("Infrastructure Node", mail_server.node)

    transition = MAIL_SERVER_TRANSITIONS.get(action)

    if not transition:
        frappe.throw(f"No transition defined for action {action}")

    current_state = mail_server.automation_state

    if current_state not in transition["from"]:
        frappe.throw(
            f"Action '{action}' not allowed from state '{current_state}'"
        )

    mail_server = frappe.get_doc("Mail Server", mail_server_name)
    node = frappe.get_doc("Infrastructure Node", mail_server.node)

    started = now_datetime()

    stdout = ""
    stderr = ""
    exit_code = -1

    try:

        if transition["to"]:
            mail_server.automation_state = transition["to"]

        mail_server.save(ignore_permissions=True)
        frappe.db.commit()

        exit_code, stdout, stderr = _execute_mail_script(
                                                        node,
                                                        mail_server,
                                                        script,
                                                        mail_user
                                                    )

        finished = now_datetime()

        if exit_code != 0:
            raise frappe.ValidationError(_extract_error(stdout, stderr, exit_code))

        # success
        success = transition.get("success")

        if success:
            next_state, next_status = success
            mail_server.automation_state = next_state
            mail_server.status = next_status

        # -----------------------------------------------------------
        # Post-success actions
        # -----------------------------------------------------------

        if action == "remove_user" and mail_user:

            frappe.delete_doc("Master Mail Users", mail_user.name, ignore_permissions=True)

        mail_server.save(ignore_permissions=True)
        frappe.db.commit()

        _log_mail_action(
            mail_server,
            action.replace("_", " ").title(),
            "Success",
            exit_code,
            stdout,
            stderr,
            started,
            finished,
        )

        return stdout

    except Exception:

        finished = now_datetime()

        traceback_msg = frappe.get_traceback()

        # merge shell stderr with python traceback
        if stderr:
            stderr = f"{stderr}\n\nPYTHON TRACEBACK:\n{traceback_msg}"
        else:
            stderr = traceback_msg

        failure = transition.get("failure")
        if failure:
            next_state, next_status = failure
            mail_server.automation_state = next_state
            mail_server.status = next_status
        else:
            mail_server.automation_state = "failed"
            mail_server.status = "Failed"

        mail_server.save(ignore_permissions=True)
        frappe.db.commit()

        _log_mail_action(
            mail_server,
            action.replace("_", " ").title(),
            "Failed",
            exit_code,
            stdout,
            stderr,
            started,
            finished,
        )

        frappe.log_error(
            title="Mail Server Automation Failed",
            message=stderr
        )

        raise


# -----------------------------------------------------------
# WHITELISTED API
# -----------------------------------------------------------

@frappe.whitelist()
def install_mail_stack(mail_server_name):
    return _run_mail_action(mail_server_name, "install_stack")


@frappe.whitelist()
def configure_postfix(mail_server_name):
    return _run_mail_action(mail_server_name, "configure_postfix")


@frappe.whitelist()
def configure_dovecot(mail_server_name):
    return _run_mail_action(mail_server_name, "configure_dovecot")


@frappe.whitelist()
def configure_rspamd(mail_server_name):
    return _run_mail_action(mail_server_name, "configure_rspamd")


@frappe.whitelist()
def configure_opendkim(mail_server_name):
    return _run_mail_action(mail_server_name, "configure_opendkim")


@frappe.whitelist()
def configure_dns(mail_server_name):
    return _run_mail_action(mail_server_name, "configure_dns")


@frappe.whitelist()
def verify_mail_server(mail_server_name):
    return _run_mail_action(mail_server_name, "verify_mail")

@frappe.whitelist()
def add_mail_user(mail_user_name):

    mail_user = frappe.get_doc("Master Mail Users", mail_user_name)
    mail_server = frappe.get_doc("Mail Server", mail_user.parent)

    return _run_mail_action(mail_server.name, "add_user", mail_user)


@frappe.whitelist()
def remove_mail_user(mail_user_name):

    mail_user = frappe.get_doc("Master Mail Users", mail_user_name)
    mail_server = frappe.get_doc("Mail Server", mail_user.parent)

    return _run_mail_action(mail_server.name, "remove_user", mail_user)


@frappe.whitelist()
def update_mail_user_password(mail_user_name):

    mail_user = frappe.get_doc("Master Mail Users", mail_user_name)
    mail_server = frappe.get_doc("Mail Server", mail_user.parent)

    return _run_mail_action(mail_server.name, "update_user_password", mail_user)

@frappe.whitelist()
def list_mail_users(mail_server_name):
    return _run_mail_action(mail_server_name, "list_users")