frappe.ui.form.on("Framework Version", {
    refresh(frm) {
        if (!frm.is_new()) {
            frm.add_custom_button("Clone Dependencies", () => {
                show_clone_dialog(frm);
            });
        }
    }
});

function show_clone_dialog(frm) {
    let d = new frappe.ui.Dialog({
        title: "Build Dependencies",
        size: "large",
        fields: [
            {
                label: "Source Framework Version",
                fieldname: "source_version",
                fieldtype: "Link",
                options: "Framework Version",
                reqd: 1
            },
            {
                fieldtype: "HTML",
                fieldname: "dependency_builder"
            }
        ],
        primary_action_label: "Apply",
        primary_action: async function () {
            let deps = d.selected_deps || [];

            await frappe.call({
                method: "dt_master.api.framework_version.apply_selected_dependencies",
                args: {
                    target_version: frm.doc.name,
                    dependencies: deps
                }
            });

            frappe.msgprint("Dependencies applied");
            d.hide();
            frm.reload_doc();
        }
    });

    d.show();

    // Load on source change
    d.fields_dict.source_version.df.change = async () => {
        let source = d.get_value("source_version");
        if (!source) return;

        let r = await frappe.call({
            method: "dt_master.api.framework_version.get_dependencies_preview",
            args: { source_version: source }
        });

        let data = r.message || {};

        // Initialize state
        d.selected_deps = [...data.base_deps];

        render_dependency_builder(d, data);
    };
}

function render_dependency_builder(d, data) {
    let wrapper = d.fields_dict.dependency_builder.$wrapper;
    wrapper.empty();

    let html = `
        <div style="display:flex; gap:20px;">

            <!-- LEFT: Available Runtime -->
            <div style="flex:1;">
                <h4>Available Runtime</h4>
                <div id="python-list"></div>
                <hr/>
                <div id="node-list"></div>
            </div>

            <!-- RIGHT: Selected Dependencies -->
            <div style="flex:2;">
                <h4>Selected Dependencies</h4>
                <div id="selected-deps" style="display:flex; flex-wrap:wrap; gap:8px;"></div>
            </div>

        </div>
    `;

    wrapper.append(html);

    let selected_container = wrapper.find("#selected-deps");

    function render_selected() {
        selected_container.empty();

        d.selected_deps.forEach((dep, index) => {
            let el = $(`
                <span class="badge badge-primary" style="cursor:pointer;">
                    ${dep.dependency} (${dep.install_order}) ✕
                </span>
            `);

            el.click(() => {
                d.selected_deps.splice(index, 1);
                render_selected();
            });

            selected_container.append(el);
        });
    }

    function add_dep(dep) {
        if (!d.selected_deps.find(d0 => d0.dependency === dep.dependency)) {
            d.selected_deps.push({
                dependency: dep.dependency,
                install_order: dep.install_order || 0
            });
            render_selected();
        }
    }

    // Render python options
    let py_list = wrapper.find("#python-list");
    data.python_deps.forEach(dep => {
        let btn = $(`<button class="btn btn-xs btn-default">${dep.dependency}</button>`);
        btn.click(() => add_dep(dep));
        py_list.append(btn);
    });

    // Render node options
    let node_list = wrapper.find("#node-list");
    data.node_deps.forEach(dep => {
        let btn = $(`<button class="btn btn-xs btn-default">${dep.dependency}</button>`);
        btn.click(() => add_dep(dep));
        node_list.append(btn);
    });

    render_selected();
}