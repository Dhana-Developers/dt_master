frappe.ui.form.on("Tenant Site", {

    refresh(frm) {

        if (!frm.is_new()) {
            setup_tenant_automation_buttons(frm);
        }

        refresh_installed_app_buttons(frm);

    }

});


/* -----------------------------------------------------------
TENANT AUTOMATION BUTTONS
----------------------------------------------------------- */

function setup_tenant_automation_buttons(frm) {

    const status = frm.doc.status;
    const automation_state = frm.doc.automation_state || "idle";

    const actions = {

        create_site: {
            status: ["Requested", "Provisioning"],
            states: ["idle", "failed"],
            method: "dt_master.api.tenant_site_executor.create_site"
        },

        install_apps: {
            status: ["Provisioning", "Active"],
            states: ["creating_site","installing_apps","ready","failed"],
            method: "dt_master.api.tenant_site_executor.install_apps"
        },

        verify_site: {
            status: ["Provisioning", "Active"],
            states: ["installing_apps","failed","ready"],
            method: "dt_master.api.tenant_site_executor.verify_site"
        },

        configure_proxy: {
            status: ["Active"],
            states: ["ready","failed"],
            method: "dt_master.api.tenant_site_executor.configure_proxy"
        },

        suspend_site: {
            status: ["Active"],
            states: ["ready"],
            method: "dt_master.api.tenant_site_executor.suspend_site"
        },

        resume_site: {
            status: ["Suspended"],
            states: ["idle"],
            method: "dt_master.api.tenant_site_executor.resume_site"
        },

        destroy_site: {
            status: ["Archived"],
            states: ["idle","failed"],
            method: "dt_master.api.tenant_site_executor.destroy_site"
        }

    };

    Object.keys(actions).forEach(label => hide_button(frm, label));

    Object.entries(actions).forEach(([label, cfg]) => {

        const status_ok = cfg.status.includes(status);
        const state_ok = cfg.states.includes(automation_state);

        const recovery_ok =
            status === "Provisioning" &&
            automation_state === "failed" &&
            cfg.status.includes("Provisioning");

        if ((status_ok && state_ok) || recovery_ok) {
            show_and_bind(frm, label, cfg.method);
        }

    });

}


/* -----------------------------------------------------------
INSTALLED APP GRID LOGIC
----------------------------------------------------------- */

function refresh_installed_app_buttons(frm) {

    const grid = frm.fields_dict.installed_apps?.grid;
    if (!grid) return;

    (grid.grid_rows || []).forEach(gr => {
        const row = gr.doc;
        update_child_row_buttons(frm, row, row.name);
    });

}

function update_child_row_buttons(frm, row, cdn) {

    const grid = frm.fields_dict.installed_apps.grid;
    const grid_row = grid.grid_rows.find(r => r.doc.name === cdn);
    if (!grid_row) return;

    const hide_all = () => {
        [
            "install",
            "upgrade",
            "downgrade",
            "reinstall",
            "uninstall",
            "check_version",
            "remove",
            "check_app"
        ].forEach(f => grid_row.toggle_display(f, false));
    };

    hide_all();

    if (["Queued","Running"].includes(row.last_action_status)) {
        return;
    }

    if (row.status === "Pending") {
        grid_row.toggle_display("install", true);
    }

    if (
        row.status === "Installed" &&
        row.installed_version &&
        row.target_version
    ) {

        const iv = parse_version(row.installed_version);
        const tv = parse_version(row.target_version);

        if (iv && tv && iv.major === tv.major) {

            const cmp = compare_versions(tv, iv);

            if (cmp > 0) grid_row.toggle_display("upgrade", true);
            if (cmp < 0) grid_row.toggle_display("downgrade", true);

        }

    }

    if (row.status === "Failed") {
        grid_row.toggle_display("reinstall", true);
    }

    if (["Installed","Disabled"].includes(row.status)) {
        grid_row.toggle_display("uninstall", true);
    }

    if (row.extension_version) {
        grid_row.toggle_display("check_version", true);
    }

    if (["Installed","Uninstalled"].includes(row.status)) {
        grid_row.toggle_display("check_app", true);
    }

    if (row.status === "Uninstalled") {
        grid_row.toggle_display("remove", true);
    }

}


/* -----------------------------------------------------------
VERSION UTILITIES
----------------------------------------------------------- */

function parse_version(v) {

    if (!v) return null;

    const parts = v.split(".").map(n => Number(n));

    if (parts.some(isNaN)) return null;

    return {
        major: parts[0] || 0,
        minor: parts[1] || 0,
        patch: parts[2] || 0
    };

}

function compare_versions(a, b) {

    const keys = ["major","minor","patch"];

    for (let k of keys) {
        if (a[k] > b[k]) return 1;
        if (a[k] < b[k]) return -1;
    }

    return 0;

}


/* -----------------------------------------------------------
ACTION DISPATCHER
----------------------------------------------------------- */

function call_app_action(frm, cdt, cdn, method) {

    const row = locals[cdt][cdn];

    if (["Queued","Running"].includes(row.last_action_status)) return;

    frappe.confirm(
        `Are you sure you want to ${method.replace("_"," ")} "${row.app_name}"?`,
        () => {

            frappe.call({
                method: `dt_master.api.tenant_installed_app_executor.${method}`,
                args: {
                    tenant_name: frm.doc.name,
                    row_name: row.name
                },
                freeze: true,
                callback() {

                    frappe.show_alert({
                        message: __("Action queued"),
                        indicator: "blue"
                    });

                    frm.reload_doc();

                }
            });

        }
    );

}


/* -----------------------------------------------------------
CHILD DOCTYPE EVENTS
----------------------------------------------------------- */

frappe.ui.form.on("Tenant Installed App", {

    form_render(frm, cdt, cdn) {
        const row = locals[cdt][cdn];
        update_child_row_buttons(frm, row, cdn);
    },

    install(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "install_app");
    },

    upgrade(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "upgrade_app");
    },

    downgrade(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "downgrade_app");
    },

    reinstall(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "reinstall_app");
    },

    uninstall(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "uninstall_app");
    },

    remove(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "remove_app");
    },

    check_version(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "check_version");
    },

    check_app(frm, cdt, cdn) {
        call_app_action(frm, cdt, cdn, "check_app");
    }

});


/* -----------------------------------------------------------
BUTTON HELPERS
----------------------------------------------------------- */

function show_and_bind(frm, label, method) {

    const btn = frm.get_field(label);
    if (!btn || !btn.$wrapper) return;

    btn.$wrapper.show();

    btn.$wrapper.off("click").on("click", () => {

        frappe.call({
            method,
            args: { tenant_name: frm.doc.name },
            freeze: true,
            freeze_message: `${label.replace("_"," ")}…`,
            callback() {
                frm.reload_doc();
            }
        });

    });

}

function hide_button(frm, label) {

    const btn = frm.get_field(label);
    if (btn && btn.$wrapper) btn.$wrapper.hide();

}
