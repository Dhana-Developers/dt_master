import frappe

class FlutterwaveLinker:

    MODULE = "flutterwave_gateway.flutterwave_gateway.doctype.flutterwave_settings.api"
    SETTINGS = "Flutterwave Settings"
    def __init__(self, gateway_instance):

        gateway = frappe.get_doc("Payment Gateway", gateway_instance)

        self.SETTINGS = gateway.gateway_controller

    def _resolve(self, path):

        full_path = f"{self.MODULE}.{path}"

        parts = full_path.split(".")

        module_path = ".".join(parts[:-1])
        fn_name = parts[-1]

        module = frappe.get_module(module_path)

        return getattr(module, fn_name)

    def _get_subscription_owner(self, invoice):

        # invoice.customer is already the ERPNext customer
        if invoice.customer:
            return invoice.customer

        # fallback if invoice was created from subscription
        if invoice.subscription:
            return frappe.db.get_value(
                "Subscription",
                invoice.subscription,
                "customer"
            )

    def _get_customer(self, erp_customer):

        customer_id = frappe.db.get_value(
            "Flutterwave Customer",
            {"customer": erp_customer},
            "flutterwave_customer_id"
        )

        if customer_id:
            return customer_id

        # Get ERPNext customer details
        customer = frappe.get_doc("Customer", erp_customer)

        email = frappe.db.get_value(
            "Contact Email",
            {"parent": customer.name},
            "email_id"
        ) or customer.email_id

        phone = frappe.db.get_value(
            "Contact Phone",
            {"parent": customer.name},
            "phone"
        )

        first_name = customer.customer_name
        last_name = ""

        fn = self._resolve("customer.create_customer")

        customer_id = fn(
            settings=self.SETTINGS,
            customer=erp_customer,
            email=email,
            first_name=first_name,
            last_name=last_name,
            phone=phone
        )

        return customer_id

    def list_payment_methods(self, erp_customer):

        customer_id = self._get_customer(erp_customer)

        fn = self._resolve("payment_methods.list_payment_methods")

        return fn(
            settings=self.SETTINGS,
            customer_id=customer_id
        )


    def charge(self, reference, amount, currency, payment_method_id):

        invoice = frappe.get_doc("Sales Invoice", reference)

        customer_id = self._get_customer(invoice.customer)

        create_fn = self._resolve("charges.create_charge")
        list_fn = self._resolve("charges.list_charges")

        try:

            create_fn(
                settings=self.SETTINGS,
                customer_id=customer_id,
                payment_method_id=payment_method_id,
                amount=amount,
                currency=currency,
                reference=reference
            )

            return True

        except Exception as e:

            error = str(e)

            if "CHARGE_ALREADY_EXISTS" in error:

                # Fetch existing charges
                charges = list_fn(settings=self.SETTINGS)

                for charge in charges:

                    if charge.get("reference") == reference:

                        if charge.get("status") in ["successful", "succeeded"]:
                            return True

                        if charge.get("status") == "failed":
                            frappe.throw("Existing charge failed")

                frappe.throw("Charge exists but could not be validated")

            frappe.log_error(
                frappe.get_traceback(),
                "Flutterwave Charge Failed"
            )

            raise

    def create_payment_method(self, reference, type, details):

        invoice = frappe.get_doc("Sales Invoice", reference)

        erp_customer = self._get_subscription_owner(invoice)

        customer_id = self._get_customer(erp_customer)

        fn = self._resolve("payment_methods.create_payment_method")

        return fn(
            settings=self.SETTINGS,
            customer_id=customer_id,
            type=type,
            details=details
        )

    def get_encryption_key(self):

        fn = self._resolve("security.get_encryption_key")

        return fn(settings=self.SETTINGS)