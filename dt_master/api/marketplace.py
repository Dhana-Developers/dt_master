import frappe

from frappe.utils import now_datetime

def _trigger_tenant_executor(tenant_name, row_name, action):

    job = frappe.enqueue(
        f"dt_master.api.tenant_installed_app_executor.{action}",
        tenant_name=tenant_name,
        row_name=row_name,
        source="tenant",
        queue="long",
        timeout=1500
    )

    frappe.logger().info(f"Executor queued: job_id={job.id}, tenant={tenant_name}, row={row_name}")

    return job

def resolve_latest_minor_version(extension):
    import subprocess

    repo = extension.repository_url

    tags = subprocess.check_output(
        ["git", "ls-remote", "--tags", repo],
        text=True
    )

    versions = []

    for line in tags.splitlines():
        tag = line.split("/")[-1]
        if tag.startswith("v"):
            tag = tag[1:]

        parts = tag.split(".")
        if len(parts) == 3:
            try:
                versions.append(tuple(map(int, parts)))
            except ValueError:
                pass

    if not versions:
        return None

    latest = max(versions)
    return ".".join(map(str, latest))


@frappe.whitelist()
def install_extension_for_tenant(extension_name, fqdn):

    tenant_name = frappe.db.get_value(
        "Tenant Site",
        {"fqdn": fqdn},
        "name"
    )

    if not tenant_name:
        frappe.throw("Tenant not found")

    tenant = frappe.get_doc("Tenant Site", tenant_name)

    # ----------------------------------------------------------------
    # Load Extension
    # ----------------------------------------------------------------
    extension = frappe.get_doc("Extension", extension_name)

    if extension.status != "Approved":
        frappe.throw("Extension not approved")

    # ----------------------------------------------------------------
    # Get latest approved version
    # ----------------------------------------------------------------
    version = frappe.db.get_value(
        "Extension Version",
        {
            "extension": extension.name,
            "status": "Approved"
        },
        ["name", "version"],
        order_by="creation desc",
        as_dict=True
    )

    if not version:
        frappe.throw("No approved version available")

    # ----------------------------------------------------------------
    # Prevent duplicates
    # ----------------------------------------------------------------
    existing_row = None

    for row in tenant.installed_apps:
        if row.extension == extension.name:
            existing_row = row
            break


    if existing_row:

        # already installed
        if existing_row.status == "Installed":
            frappe.throw("Extension already installed")

        # installation already running
        if existing_row.status == "Pending":
            frappe.throw("Extension installation already in progress")

        # retry if failed
        if existing_row.status == "Failed":
            existing_row.status = "Pending"
            existing_row.last_error = None
            existing_row.last_updated = now_datetime()

            tenant.save(ignore_permissions=True)
            frappe.db.commit()

            job = _trigger_tenant_executor(tenant.site_name, existing_row.name, "install_app")

            return {
                "status": "retrying",
                "row": existing_row.name,
                "job_id": job.id
            }

        # reinstall if previously removed
        if existing_row.status == "Uninstalled":
            existing_row.status = "Pending"
            existing_row.last_updated = now_datetime()

            tenant.save(ignore_permissions=True)
            frappe.db.commit()

            job = _trigger_tenant_executor(tenant.site_name, existing_row.name)

            return {
                "status": "reinstalling",
                "row": existing_row.name,
                "job_id": job.id
            }

    # ----------------------------------------------------------------
    # Create Installed App row
    # ----------------------------------------------------------------
    resolved_version = resolve_latest_minor_version(extension)
    
    row = tenant.append("installed_apps", {
        "app_name": extension.app_name,
        "app_type": "Marketplace",

        "extension": extension.name,
        "extension_version": version.name,

        "target_version": resolved_version,

        "git_branch": extension.default_branch,

        "status": "Pending",
        "enabled": 1,
        "sync_state": "Pending",

        "last_updated": now_datetime(),
        "last_action_status":"Success"
    })

    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    # ----------------------------------------------------------------
    # Trigger tenant executor
    # ----------------------------------------------------------------
    job = _trigger_tenant_executor(tenant.site_name, row.name)

    return {
        "status": "queued",
        "row": row.name,
        "job_id": job.id
    }


@frappe.whitelist()
def upgrade_extension_for_tenant(extension_name, fqdn):

    tenant_name = frappe.db.get_value(
        "Tenant Site",
        {"fqdn": fqdn},
        "name"
    )

    if not tenant_name:
        frappe.throw("Tenant not found")

    tenant = frappe.get_doc("Tenant Site", tenant_name)
    extension = frappe.get_doc("Extension", extension_name)

    existing_row = None

    for row in tenant.installed_apps:
        if row.extension == extension.name:
            existing_row = row
            break

    if not existing_row:
        frappe.throw("Extension not installed")

    if existing_row.status != "Installed":
        frappe.throw("Extension must be installed to upgrade")

    resolved_version = resolve_latest_minor_version(extension)

    if not resolved_version:
        frappe.throw("Unable to resolve latest version")

    if existing_row.installed_version == resolved_version:
        frappe.throw("Extension already on latest version")

    existing_row.target_version = resolved_version
    existing_row.status = "Pending"
    existing_row.last_updated = now_datetime()
    existing_row.last_action_status = "Pending"

    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    job = _trigger_tenant_executor(tenant.site_name, existing_row.name, "upgrade_app")

    return {
        "status": "upgrade_queued",
        "row": existing_row.name,
        "job_id": job.id
    }

@frappe.whitelist()
def uninstall_extension_for_tenant(extension_name, fqdn):

    tenant_name = frappe.db.get_value(
        "Tenant Site",
        {"fqdn": fqdn},
        "name"
    )

    if not tenant_name:
        frappe.throw("Tenant not found")

    tenant = frappe.get_doc("Tenant Site", tenant_name)

    existing_row = None

    for row in tenant.installed_apps:
        if row.extension == extension_name:
            existing_row = row
            break

    if not existing_row:
        frappe.throw("Extension not installed")

    if existing_row.status != "Installed":
        frappe.throw("Extension is not installed")

    existing_row.status = "Pending"
    existing_row.last_action_status = "Pending"
    existing_row.last_updated = now_datetime()

    tenant.save(ignore_permissions=True)
    frappe.db.commit()

    job = _trigger_tenant_executor(tenant.site_name, existing_row.name, "uninstall_app")

    return {
        "status": "uninstall_queued",
        "row": existing_row.name,
        "job_id": job.id
    }