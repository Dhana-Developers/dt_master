import frappe

@frappe.whitelist()
def get_tenant_capabilities(fqdn):
    # Normalize fqdn (defensive)
    fqdn = fqdn.split(":")[0]

    # 1. Resolve tenant
    tenant = frappe.get_value(
        "Tenant Site",
        {
            "fqdn": fqdn,
            "status": ["in", ["Requested", "Active"]]
        },
        ["subscription", "status"],
        as_dict=True
    )

    if not tenant:
        frappe.throw("Invalid or inactive tenant")

    # 2. Load subscription
    subscription = frappe.get_doc("Subscription", tenant.subscription)

    if not subscription.plans:
        frappe.throw("Subscription has no plans")

    # 3. Pick primary plan (first one)
    plan_name = subscription.plans[0].plan

    # 4. Resolve capability profile from subscription plan
    profile_name = frappe.get_value(
        "Capability Profile",
        {"subscription_plan": plan_name},
        "name"
    )

    if not profile_name:
        frappe.throw(f"No capability profile linked to plan {plan_name}")

    profile = frappe.get_doc("Capability Profile", profile_name)

    # 5. Return capabilities
    return {
        "subscription_status": subscription.status,
        "trial_period_end": subscription.trial_period_end,
        "end_date": subscription.end_date,
        "subscription_plan": plan_name,
        "capability_profile": profile.name,
        "allowed_roles": [r.role for r in profile.allowed_roles],
        "allowed_modules": [m.module for m in profile.allowed_modules],
    }
