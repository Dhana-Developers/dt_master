import frappe
from frappe.utils.pdf import get_pdf
from erpnext.accounts.doctype.payment_entry.payment_entry import get_payment_entry


GATEWAY_REGISTRY = {
    "Debit/Credit Card": "dt_master.api.flutterwave_linker.FlutterwaveLinker",
    "MPesa": "dt_master.api.mpesa_linker.MpesaLinker"
}
MODE_OF_PAYMENT_MAP = {
    "Flutterwave": "Flutterwave"
}


def get_gateway_linker(gateway, gateway_instance):

    if gateway not in GATEWAY_REGISTRY:
        frappe.throw(f"Unsupported gateway: {gateway}")

    linker_path = GATEWAY_REGISTRY[gateway]

    return frappe.get_attr(linker_path)(gateway_instance)

def _get_or_retry_payment_request(invoice, gateway_instance,phone):

    pr_name = frappe.db.get_value(
        "Payment Request",
        {
            "reference_doctype": "Sales Invoice",
            "reference_name": invoice.name,
            "docstatus": ["!=", 2]
        },
        "name",
        order_by="creation desc"
    )

    if pr_name:
        pr = frappe.get_doc("Payment Request", pr_name)

        # cancel existing request
        if pr.docstatus == 1:
            pr.cancel()

        # amend to preserve audit trail
        amended = frappe.copy_doc(pr)
        amended.amended_from = pr.name
        amended.contact_mobile = phone
        amended.insert(ignore_permissions=True)
        amended.submit()

        return amended

    # first payment attempt
    pr = frappe.new_doc("Payment Request")

    pr = frappe.new_doc("Payment Request")

    pr.payment_request_type = "Inward"
    pr.party_type = "Customer"
    pr.party = invoice.customer

    pr.reference_doctype = "Sales Invoice"
    pr.reference_name = invoice.name

    pr.payment_gateway = gateway_instance

    pr.grand_total = invoice.outstanding_amount
    pr.currency = invoice.currency
    pr.contact_mobile = phone

    pr.subject = f"Payment request for invoice {invoice.name}"

    pr.insert(ignore_permissions=True)
    pr.submit()

    return pr

    frappe.throw("Unable to determine subscription customer")


def _create_payment_entry(invoice, gateway):

    mode_of_payment = MODE_OF_PAYMENT_MAP.get(gateway)

    if not mode_of_payment:
        frappe.throw(f"No Mode of Payment configured for gateway {gateway}")

    payment_entry = get_payment_entry(
        dt="Sales Invoice",
        dn=invoice.name
    )

    payment_entry.mode_of_payment = mode_of_payment
    payment_entry.reference_no = f"GW-{invoice.name}"
    payment_entry.reference_date = frappe.utils.nowdate()

    payment_entry.insert(ignore_permissions=True)
    payment_entry.submit()

    return payment_entry

@frappe.whitelist()
def download_invoice_pdf(invoice_name,prt_format):

    # temporarily elevate permissions
    original_user = frappe.session.user
    frappe.set_user("Administrator")

    try:
        html = frappe.get_print("Sales Invoice", invoice_name, prt_format)
        pdf = get_pdf(html)

        frappe.local.response.filename = f"{invoice_name}.pdf"
        frappe.local.response.filecontent = pdf
        frappe.local.response.type = "download"

    finally:
        frappe.set_user(original_user)

@frappe.whitelist()
def get_payment_gateways(fqdn):

    gateways = frappe.get_all(
        "Payment Gateway",
        fields=[
            "name",
            "gateway",
            "gateway_settings",
            "gateway_controller"
        ]
    )

    result = []

    for g in gateways:

        controller = (g.gateway_controller or "").lower()

        gateway_type = None
        requires_methods = False

        if "flutterwave" in controller:
            gateway_type = "Debit/Credit Card"
            requires_methods = True

        elif "mpesa" in controller or "m-pesa" in controller:
            gateway_type = "MPesa"

        else:
            continue

        result.append({
            "instance": g.name,                 # gateway instance
            "label": gateway_type,              # UI label
            "type": gateway_type,               # linker type
            "controller": g.gateway_controller, # controller
            "settings": g.gateway_settings,
            "requires_payment_method": requires_methods
        })

    return result

@frappe.whitelist()
def pay_invoice(invoice_name, gateway, gateway_instance, payment_method_id=None, phone=None):

    invoice = frappe.get_doc("Sales Invoice", invoice_name)

    if invoice.outstanding_amount <= 0:
        subscription_name = invoice.subscription

        if subscription_name:
            subscription = frappe.get_doc("Subscription", subscription_name)
            subscription.set_subscription_status()
            subscription.save(ignore_permissions=True)
        frappe.throw("Invoice already paid")

    # MPESA FLOW (asynchronous)
    if gateway == "MPesa":

        pr = _get_or_retry_payment_request(invoice, gateway_instance,phone)

        return {
            "success": True,
            "status": "pending",
            "payment_request": pr.name
        }

    # CARD / SYNCHRONOUS FLOW
    mode_of_payment = MODE_OF_PAYMENT_MAP.get(gateway)
    # ADD THE VALIDATION HERE
    if not frappe.db.exists("Mode of Payment", mode_of_payment):
        frappe.throw(f"Mode of Payment '{mode_of_payment}' does not exist")

    linker = get_gateway_linker(gateway, gateway_instance)

    success = linker.charge(
        reference=invoice.name,
        amount=invoice.outstanding_amount,
        currency=invoice.currency,
        payment_method_id=payment_method_id
    )

    if not success:
        frappe.throw("Payment failed")

    payment_entry = _create_payment_entry(invoice, gateway)

    subscription_name = invoice.subscription

    if subscription_name:
        subscription = frappe.get_doc("Subscription", subscription_name)
        subscription.set_subscription_status()
        subscription.save(ignore_permissions=True)

    return {
        "success": True,
        "payment_entry": payment_entry.name
    }

@frappe.whitelist()
def get_payment_methods(invoice_name, gateway, gateway_instance):

    invoice = frappe.get_doc("Sales Invoice", invoice_name)

    linker = get_gateway_linker(gateway, gateway_instance)

    if not hasattr(linker, "list_payment_methods"):
        frappe.throw(f"{gateway} does not support saved payment methods")

    return linker.list_payment_methods(invoice.customer)

@frappe.whitelist()
@frappe.whitelist()
def create_payment_method(gateway, gateway_instance, reference, type, details):

    linker = get_gateway_linker(gateway, gateway_instance)

    if not hasattr(linker, "create_payment_method"):
        frappe.throw(f"{gateway} does not support creating payment methods")

    return linker.create_payment_method(
        reference=reference,
        type=type,
        details=details
    )

@frappe.whitelist()
def get_encryption_key(gateway, gateway_instance):

    linker = get_gateway_linker(gateway, gateway_instance)

    if not hasattr(linker, "get_encryption_key"):
        frappe.throw(f"{gateway} does not support encryption")

    return linker.get_encryption_key()