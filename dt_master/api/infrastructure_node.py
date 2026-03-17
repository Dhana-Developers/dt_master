import subprocess
import shlex
import datetime
import json
import base64

import frappe
from frappe.utils import now_datetime


BASE_DIR="/home/frank/scripts"
SCRIPT_BASE_DIR = f"{BASE_DIR}/bin/node/"
SCRIPT_LIB_DIR = f"{BASE_DIR}/lib/"

ALLOWED_TRANSITIONS = {
    "Declared": ["SSH Ready","Error"],
    "SSH Ready": ["Deps Installed","Error"],
    "Deps Installed": ["Project Installed","Error"],
    "Project Installed": ["Initialized","Error"],
    "Initialized": ["Healthy","Error"],
    "Healthy": ["Running","Error"],
    "Running": ["Stopped","Error"],
    "Stopped": ["Running","Error"],
    "Error": ["Error","Stopped","Running","Healthy","Initialized","Project Installed","Deps Installed","SSH Ready","Declared"],
}
ALLOWED_STATUS_TRANSITIONS = {
    "Provisioning": ["Active", "Maintenance","Provisioning"],
    "Active": ["Maintenance", "Retired", "Active"],
    "Maintenance": ["Provisioning", "Active", "Retired","Maintenance"],
    "Retired": [],
}

NODE_TRANSITIONS = {
    "install_dependencies": {
        # Normal forward path
        "from": ["SSH Ready"],
        # Recovery path (retry after failure)
        "recover_from": ["Error"],
        # Outcomes
        "success": ("Deps Installed", "Provisioning"),
        "failure": ("Error", "Maintenance"),
    },
    "install_bench": {
        "from": ["Deps Installed"],
        "recover_from": ["Error"],
        "success": ("Project Installed", "Provisioning"),
        "failure": ("Error", "Maintenance"),
    },
    "init_project": {
        "from": ["Project Installed"],
        "recover_from": ["Error"],
        "success": ("Initialized", "Provisioning"),
        "failure": ("Error", "Maintenance"),
    },
    "prepare_production": {
        "from": ["Initialized"],
        "recover_from": ["Error"],
        "success": ("Healthy", "Active"),
        "failure": ("Error", "Maintenance"),
    },
    "start_project": {
        "from": ["Healthy", "Stopped"],
        "recover_from": ["Error"],
        "success": ("Running", "Active"),
        "failure": ("Error", "Maintenance"),
    },
    "stop_project": {
        "from": ["Running"],
        "recover_from": [],
        "success": ("Stopped", "Active"),
        "failure": ("Error", "Maintenance"),
    },
    "verify_production": {
        "from": ["Healthy", "Running", "Stopped",'SSH Ready'],
        "recover_from": [],
        "success": (None, None),          # no state/status change
        "failure": ("Error", "Maintenance"),
    },
}


def _validate_status_transition(current, next_):
    allowed = ALLOWED_STATUS_TRANSITIONS.get(current, [])
    if next_ not in allowed:
        frappe.throw(
            f"Invalid status transition: '{current}' → '{next_}'"
        )

def _validate_transition(from_state, to_state):
    if from_state == to_state:
        return
    if to_state not in ALLOWED_TRANSITIONS.get(from_state, []):
        frappe.throw(f"Invalid node state transition: {from_state} → {to_state}")


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
        "port": node.ssh_port or 22
    }

def _get_node_dependencies(node):
    deps = frappe.get_all(
        "Framework Version Dependency",
        filters={
            "framework_version": node.frappe_version,
            "enabled": 1
        },
        fields=["dependency", "install_order"],
        order_by="install_order asc"
    )

    result = []

    for d in deps:
        dep = frappe.get_doc("System Dependency", d.dependency)

        result.append({
            "name": dep.name,
            "install_method": dep.install_method,
            "group": dep.dependency_group,
            "version": getattr(dep, "version", None),
            "repository": dep.repository,
        })

    return result

import json

def _execute_ssh_script(node, script_name):
    ssh = _get_ssh_config(node)

    if not node.scripts_base_dir:
        frappe.throw("Scripts base directory not configured on node")

    SCRIPT_BASE_DIR = f"{node.scripts_base_dir}/bin/node"
    SCRIPT_LIB_DIR = f"{node.scripts_base_dir}/lib"

    # -------------------------------------------------
    # Resolve Framework Version Doc
    # -------------------------------------------------
    fv = frappe.get_doc("Framework Version", node.frappe_version)

    frappe_context = {
        "name": fv.name,
        "framework": fv.framework,
        "version": fv.version,
        "python_version": fv.python_version,
        "node_version": fv.node_version,
        "bench_package": fv.bench_package,
        "description": fv.description,
    }

    # -------------------------------------------------
    # Dependencies
    # -------------------------------------------------
    deps = _get_node_dependencies(node)
    encoded = base64.b64encode(json.dumps(frappe_context).encode()).decode()
    # -------------------------------------------------
    # Environment exports
    # -------------------------------------------------
    env_exports = (
        f"export PROJECT_BASE_DIR='{node.project_base_dir}'; "
        f"export PROJECT_LOGS_DIR='{node.project_logs_dir}'; "

        # 🔥 Correct version (not doc name)
        f"export FRAPPE_VERSION='{fv.version}'; "
        f"export FRAMEWORK_NAME='{fv.framework}'; "

        # Runtime hints
        f"export PYTHON_VERSION='{fv.python_version or ''}'; "
        f"export NODE_VERSION='{fv.node_version or ''}'; "
        f"export BENCH_PACKAGE='{fv.bench_package or ''}'; "

        # Paths
        f"export SCRIPT_BASE_DIR='{SCRIPT_BASE_DIR}'; "
        f"export SCRIPT_LIB_DIR='{SCRIPT_LIB_DIR}'; "
        f"export BASE_DIR='{BASE_DIR}'; "

        # Full structured context (future-proof)
        # f"export FRAMEWORK_CONTEXT='{json.dumps(frappe_context)}'; "

        # Dependency graph
        f"export SYSTEM_DEPENDENCIES='{json.dumps(deps)}'; "
    )

    env_exports += f"export FRAMEWORK_CONTEXT_B64='{encoded}'; "

    remote_cmd = (
        f"sudo -n bash -c "
        f"{shlex.quote(env_exports + f'bash {SCRIPT_BASE_DIR}/{script_name}')}"
    )

    ssh_command = (
        f"ssh -p {ssh['port']} "
        f"{ssh['user']}@{ssh['host']} "
        f"{shlex.quote(remote_cmd)}"
    )

    process = subprocess.Popen(
        ssh_command,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )

    stdout_lines = []

    for line in iter(process.stdout.readline, ''):
        line = line.rstrip()
        stdout_lines.append(line)

        frappe.publish_realtime(
            "script_execution_log",
            {
                "execution": script_name,
                "line": line
            },
            user=frappe.session.user
        )

    process.wait()

    stdout = "\n".join(stdout_lines)
    stderr = ""

    exec_status = "Completed" if process.returncode == 0 else "Failed"

    frappe.publish_realtime(
        "script_execution_log",
        {
            "execution": script_name,
            "status": exec_status
        },
        user=frappe.session.user
    )

    return process.returncode, stdout, stderr

def _log_node_action(
    node,
    action_name,
    action_type,
    state_before,
    state_after,
    result,
    exit_code,
    stdout,
    stderr,
    started_at=None,
    finished_at=None
):
    node.append("node_action_logs", {
        "action_name": action_name,
        "action_type": action_type,
        "triggered_by": frappe.session.user,
        "started_at": started_at or datetime.datetime.now(),
        "finished_at": finished_at or datetime.datetime.now(),
        "node_state_before": state_before,
        "node_state_after": state_after,
        "result": result,
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr
    })

    node.save(ignore_permissions=True)
    frappe.db.commit()

@frappe.whitelist()
def install_dependencies(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("install_dependencies")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states (normal + recovery)
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for install_dependencies"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute remote script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node, "install_deps.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve transition outcome
    # -------------------------------------------------
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

    # -------------------------------------------------
    # Validate FSM transitions
    # -------------------------------------------------
    _validate_transition(state_before, next_state)
    _validate_status_transition(status_before, next_status)

    # -------------------------------------------------
    # Apply transition
    # -------------------------------------------------
    node.state = next_state
    node.status = next_status
    node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Install Dependencies",
        action_type="Install",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Dependency installation failed. Node moved to Error/Maintenance."
        )

    return "Dependencies installed successfully"

@frappe.whitelist()
def install_bench(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("install_bench")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states (normal + recovery)
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for install_bench"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute remote script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node, "install_bench.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve transition outcome
    # -------------------------------------------------
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

    # -------------------------------------------------
    # Validate FSM transitions
    # -------------------------------------------------
    _validate_transition(state_before, next_state)
    _validate_status_transition(status_before, next_status)

    # -------------------------------------------------
    # Apply transition
    # -------------------------------------------------
    node.state = next_state
    node.status = next_status
    node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Install Bench",
        action_type="Install",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Bench installation failed. Node moved to Error/Maintenance."
        )

    return "Bench installed successfully"

@frappe.whitelist()
def init_project(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("init_project")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states (normal + recovery)
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for init_project"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute remote script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node, "init_project.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve transition outcome
    # -------------------------------------------------
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

    # -------------------------------------------------
    # Validate FSM transitions
    # -------------------------------------------------
    _validate_transition(state_before, next_state)
    _validate_status_transition(status_before, next_status)

    # -------------------------------------------------
    # Apply transition
    # -------------------------------------------------
    node.state = next_state
    node.status = next_status
    node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log (with timing)
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Initialize Project",
        action_type="Control",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Project initialization failed. Node moved to Error/Maintenance."
        )

    return "Project initialized successfully"

@frappe.whitelist()
def prepare_production(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("prepare_production")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states (normal + recovery)
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for prepare_production"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute remote script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node,
        "prepare_production.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve transition outcome
    # -------------------------------------------------
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

    # -------------------------------------------------
    # Validate FSM transitions
    # -------------------------------------------------
    _validate_transition(state_before, next_state)
    _validate_status_transition(status_before, next_status)

    # -------------------------------------------------
    # Apply transition
    # -------------------------------------------------
    node.state = next_state
    node.status = next_status
    node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log (with timing)
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Prepare Production",
        action_type="Health",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Production preparation failed. Node moved to Error/Maintenance."
        )

    return "Production environment prepared successfully"

@frappe.whitelist()
def verify_production(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("verify_production")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for verify_production"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute verification script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node,
        "verify_production.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve outcome
    # -------------------------------------------------
    if exit_code == 0:
        result = "Success"
        next_state, next_status = transition["success"]
    else:
        result = "Failed"
        next_state, next_status = transition["failure"]

    # -------------------------------------------------
    # Apply transition ONLY on failure
    # -------------------------------------------------
    if next_state:
        _validate_transition(state_before, next_state)
        _validate_status_transition(status_before, next_status)

        node.state = next_state
        node.status = next_status
        node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log (with timing)
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Verify Production Environment",
        action_type="Health",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on verification error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Production verification failed. Node moved to Error/Maintenance."
        )

    # Verification returns raw report
    return stdout


@frappe.whitelist()
def start_project(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("start_project")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states (normal + recovery)
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for start_project"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute remote script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node,
        "start_production_services.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve transition outcome
    # -------------------------------------------------
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

    # -------------------------------------------------
    # Validate FSM transitions
    # -------------------------------------------------
    _validate_transition(state_before, next_state)
    _validate_status_transition(status_before, next_status)

    # -------------------------------------------------
    # Apply transition
    # -------------------------------------------------
    node.state = next_state
    node.status = next_status
    node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log (with timing)
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Start Production Services",
        action_type="Control",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Failed to start production services. Node moved to Error/Maintenance."
        )

    return "Production services started successfully"

@frappe.whitelist()
def stop_project(node_name):
    node = frappe.get_doc("Infrastructure Node", node_name)

    transition = NODE_TRANSITIONS.get("stop_project")
    if not transition:
        frappe.throw("Transition not configured")

    # -------------------------------------------------
    # Allowed entry states
    # -------------------------------------------------
    allowed_states = []
    allowed_states.extend(transition.get("from", []))
    allowed_states.extend(transition.get("recover_from", []))

    if node.state not in allowed_states:
        frappe.throw(
            f"Invalid node state '{node.state}' for stop_project"
        )

    state_before = node.state
    status_before = node.status

    # -------------------------------------------------
    # Capture start time
    # -------------------------------------------------
    started_at = now_datetime()

    # -------------------------------------------------
    # Execute remote script
    # -------------------------------------------------
    exit_code, stdout, stderr = _execute_ssh_script(
        node,
        "stop_production_services.sh"
    )

    # -------------------------------------------------
    # Capture finish time
    # -------------------------------------------------
    finished_at = now_datetime()

    # -------------------------------------------------
    # Resolve transition outcome
    # -------------------------------------------------
    if exit_code == 0:
        next_state, next_status = transition["success"]
        result = "Success"
    else:
        next_state, next_status = transition["failure"]
        result = "Failed"

    # -------------------------------------------------
    # Validate FSM transitions
    # -------------------------------------------------
    _validate_transition(state_before, next_state)
    _validate_status_transition(status_before, next_status)

    # -------------------------------------------------
    # Apply transition
    # -------------------------------------------------
    node.state = next_state
    node.status = next_status
    node.save(ignore_permissions=True)

    # -------------------------------------------------
    # Audit log (with timing)
    # -------------------------------------------------
    _log_node_action(
        node=node,
        action_name="Stop Production Services",
        action_type="Control",
        state_before=state_before,
        state_after=node.state,
        result=result,
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        started_at=started_at,
        finished_at=finished_at,
    )

    # -------------------------------------------------
    # Hard fail on error
    # -------------------------------------------------
    if exit_code != 0:
        frappe.throw(
            "Failed to stop production services. Node moved to Error/Maintenance."
        )

    return "Production services stopped successfully"

