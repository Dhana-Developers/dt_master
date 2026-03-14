frappe.ui.form.on("Infrastructure Node", {
    refresh(frm) {
        if (frm.is_new()) return;

        const { status, state } = frm.doc;

        const actions = {
            install_dependencies: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["SSH Ready","Error"],
                method: "dt_master.api.infrastructure_node.install_dependencies"
            },

            install_bench: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["Deps Installed","Error"],
                method: "dt_master.api.infrastructure_node.install_bench"
            },

            initialize_project: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["Project Installed","Error"],
                method: "dt_master.api.infrastructure_node.init_project"
            },

            prepare_project: {
                statuses: ["Provisioning", "Maintenance"],
                states: ["Initialized","Error"],
                method: "dt_master.api.infrastructure_node.prepare_production"
            },

            start_project: {
                statuses: ["Active", "Maintenance"],
                states: ["Healthy", "Stopped"],
                method: "dt_master.api.infrastructure_node.start_project"
            },

            stop_project: {
                statuses: ["Active", "Maintenance"],
                states: ["Running"],
                method: "dt_master.api.infrastructure_node.stop_project"
            },

            check_system_status: {
                statuses: ["Provisioning", "Active", "Maintenance"],
                states: ["SSH Ready", "Healthy", "Running", "Stopped"],
                method: "dt_master.api.infrastructure_node.verify_production"
            }
        };

        // 1. Hard reset UI
        Object.keys(actions).forEach(label => hide_button(frm, label));

        // 2. Evaluate lifecycle rules
        Object.entries(actions).forEach(([label, cfg]) => {
            const status_ok = cfg.statuses.includes(status);
            const state_ok  = cfg.states.includes(state);

            if (status_ok && state_ok) {
                show_and_bind(frm, label, cfg.method);
            }
        });
    }
});
function show_and_bind(frm, label, method) {
    const btn = frm.get_field(label);
    if (!btn) return;

    btn.$wrapper.show();
    btn.$wrapper.off("click").on("click", () => {
        frappe.call({
            method,
            args: { node_name: frm.doc.name },
            freeze: true,
            freeze_message: `${label.replace("_", " ")}…`,
            callback() {
                frm.reload_doc();
            }
        });
    });
}

function hide_button(frm, label) {
    const btn = frm.get_field(label);
    if (btn) btn.$wrapper.hide();
}
