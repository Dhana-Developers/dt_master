import requests

import frappe

def tenant_base_url(tenant):
    protocol = (tenant.protocol or "https").lower().replace("://", "")
    port = tenant.port

    if port:
        return f"{protocol}://{tenant.fqdn}:{port}"
    return f"{protocol}://{tenant.fqdn}"

def _ensure_site_reachable(tenant):
    url = tenant_base_url(tenant)

    try:
        r = requests.get(url, timeout=5)
        if r.status_code >= 400:
            raise Exception(f"Tenant site unreachable: {r.status_code}")
    except Exception as e:
        raise Exception(f"Tenant site not reachable: {str(e)}")

def _tenant_bootstrap_call(tenant, path, data=None, unauthenticated=False):
    url = f"{tenant_base_url(tenant)}{path}"

    headers = {"Content-Type": "application/json"}

    # Bootstrap phase uses Administrator session or allow_guest
    r = requests.post(url, json=data or {}, headers=headers, timeout=10)
    r.raise_for_status()
    return r.json()

def _ensure_master_api_user_and_keys(tenant):
    # If already provisioned, skip (idempotent)
    if tenant.tenant_api_key and tenant.get_password("tenant_api_secret"):
        return

    # 1. Create API user on tenant
    email = f"master-api@{tenant.fqdn}"

    payload = {
        "email": email,
        "first_name": "Master API",
        "enabled": 1,
        "user_type": "System User",
        "roles": ["System Manager"],
    }

    _tenant_bootstrap_call(
        tenant,
        "/api/method/frappe.core.doctype.user.user.create_user",
        payload,
        unauthenticated=True
    )

    # 2. Generate API keys
    resp = _tenant_bootstrap_call(
        tenant,
        "/api/method/frappe.core.doctype.user.user.generate_keys",
        {"user": email},
        unauthenticated=True
    )

    api_key = resp["message"]["api_key"]
    api_secret = resp["message"]["api_secret"]

    # 3. Store securely on master
    tenant.tenant_api_user = email
    tenant.tenant_api_key = api_key
    tenant.tenant_api_secret = api_secret
    tenant.save()


def _ensure_tenant_app_installed(tenant):
    resp = _tenant_api_call(
        tenant,
        "/api/method/dt_tenant.api.system.is_app_installed",
        {"app_name": "dt_tenant"}
    )

    if not resp.get("message", {}).get("installed"):
        raise Exception("dt_tenant app not installed on tenant site")

def _configure_tenant_settings(tenant):
    payload = {
        "master_url": frappe.utils.get_url(),
        "enable_capability_sync": 1,
    }

    _tenant_api_call(
        tenant,
        "/api/method/dt_tenant.api.settings.configure",
        payload
    )

def _initial_capability_sync(tenant):
    _tenant_api_call(
        tenant,
        "/api/method/dt_tenant.controllers.capability_sync.resync_capabilities"
    )

def _ensure_admin_user(tenant):
    resp = _tenant_api_call(
        tenant,
        "/api/method/dt_tenant.api.system.has_active_system_manager"
    )

    if not resp.get("message"):
        raise Exception("No active System Manager found on tenant site")


def _tenant_api_call(tenant, path, data=None):
    url = tenant_base_url(tenant) + path

    headers = {
        "Authorization": f"token {tenant.tenant_api_key}:{tenant.tenant_api_secret}",
        "Content-Type": "application/json",
    }

    r = requests.post(url, json=data or {}, headers=headers, timeout=10)
    r.raise_for_status()
    return r.json()


@frappe.whitelist()
def provision_tenant(site_name):
    tenant = frappe.get_doc("Tenant Site", site_name)
    tenant.status = "Provisioning"
    tenant.save()

    steps = [
        _ensure_site_reachable,
        _ensure_tenant_app_installed,
        _configure_tenant_settings,
        _initial_capability_sync,
        _ensure_admin_user,
    ]

    try:
        for step in steps:
            step(tenant)
    except Exception as e:
        tenant.status = "Failed"
        tenant.save()
        frappe.throw(str(e))

    tenant.status = "Active"
    tenant.save()
    return {"status": "active"}
