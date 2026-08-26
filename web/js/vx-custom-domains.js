(function (root, factory) {
    'use strict';

    var api = factory();
    if (typeof module === 'object' && module.exports) {
        module.exports = api;
    }
    if (root) {
        root.VXCustomDomains = api;
    }
}(typeof window !== 'undefined' ? window : null, function () {
    'use strict';

    function normalizeDomain(value) {
        return String(value || '').replace(/^\s+|\s+$/g, '').toLowerCase().replace(/\.+$/, '');
    }

    function isValidDomain(value) {
        var domain = normalizeDomain(value);
        var labels;
        var i;

        if (!domain || domain.length > 253 || domain.indexOf('.') === -1 || domain.indexOf('..') !== -1) {
            return false;
        }
        if (!/^[a-z0-9.-]+$/.test(domain) || /^\d+(?:\.\d+){3}$/.test(domain)) {
            return false;
        }
        labels = domain.split('.');
        if (!/[a-z]/.test(labels[labels.length - 1])) {
            return false;
        }
        for (i = 0; i < labels.length; i += 1) {
            if (labels[i].length < 1 || labels[i].length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(labels[i])) {
                return false;
            }
        }
        return true;
    }

    function serializeDomains(values) {
        var domains = [];
        var i;
        var domain;

        for (i = 0; i < values.length; i += 1) {
            domain = normalizeDomain(values[i]);
            if (domain) {
                domains.push(domain);
            }
        }
        return domains.join('\n');
    }

    function validateDomains(values, primaryDomain, maxDomains) {
        var normalized = [];
        var seen = {};
        var primary = normalizeDomain(primaryDomain);
        var nonempty = 0;
        var i;
        var domain;

        for (i = 0; i < values.length; i += 1) {
            domain = normalizeDomain(values[i]);
            normalized.push(domain);
            if (!domain) {
                if (values.length > 1) {
                    return { valid: false, index: i, reason: 'empty', values: normalized };
                }
                continue;
            }
            nonempty += 1;
            if (!isValidDomain(domain)) {
                return { valid: false, index: i, reason: 'invalid', values: normalized };
            }
            if (primary && domain === primary) {
                return { valid: false, index: i, reason: 'primary', values: normalized };
            }
            if (seen[domain]) {
                return { valid: false, index: i, reason: 'duplicate', values: normalized };
            }
            seen[domain] = true;
        }
        if (nonempty > maxDomains) {
            return { valid: false, index: normalized.length - 1, reason: 'limit', values: normalized };
        }
        return { valid: true, index: -1, reason: '', values: normalized };
    }

    function dispatchChange(element) {
        var event;
        if (!element || !element.dispatchEvent || !document.createEvent) {
            return;
        }
        event = document.createEvent('HTMLEvents');
        event.initEvent('change', true, false);
        element.dispatchEvent(event);
    }

    function initComponent(component) {
        var rows = component.querySelector('[data-vx-custom-domain-rows]');
        var hidden = component.querySelector('textarea[name="v_aliases"]');
        var error = component.querySelector('[data-vx-custom-domain-error]');
        var form = component.closest ? component.closest('form') : null;
        var primary = component.getAttribute('data-primary-domain') || '';
        var max = parseInt(component.getAttribute('data-max-domains'), 10) || 199;

        if (!rows || !hidden || !form) {
            return;
        }

        function inputs() {
            return rows.querySelectorAll('[data-vx-custom-domain-input]');
        }

        function values() {
            var fields = inputs();
            var result = [];
            var i;
            for (i = 0; i < fields.length; i += 1) {
                result.push(fields[i].value);
            }
            return result;
        }

        function refreshControls() {
            var rowNodes = rows.querySelectorAll('[data-vx-custom-domain-row]');
            var i;
            var add;
            var remove;
            for (i = 0; i < rowNodes.length; i += 1) {
                add = rowNodes[i].querySelector('[data-vx-custom-domain-add]');
                remove = rowNodes[i].querySelector('[data-vx-custom-domain-remove]');
                add.hidden = i !== rowNodes.length - 1 || rowNodes.length >= max;
                remove.hidden = rowNodes.length === 1 && !normalizeDomain(rowNodes[i].querySelector('[data-vx-custom-domain-input]').value);
            }
        }

        function messageFor(reason) {
            return component.getAttribute('data-' + reason + '-message') || '';
        }

        function clearErrors() {
            var fields = inputs();
            var i;
            for (i = 0; i < fields.length; i += 1) {
                fields[i].setCustomValidity('');
                fields[i].removeAttribute('aria-invalid');
                fields[i].classList.remove('is-invalid');
            }
            error.textContent = '';
            error.classList.remove('is-visible');
        }

        function sync(notify) {
            var serialized = serializeDomains(values());
            if (hidden.value !== serialized) {
                hidden.value = serialized;
                if (notify) {
                    dispatchChange(hidden);
                }
            }
        }

        function validate(report) {
            var result;
            var fields;
            var field;
            var message;

            clearErrors();
            result = validateDomains(values(), primary, max);
            if (result.valid) {
                sync(false);
                return true;
            }
            fields = inputs();
            field = fields[result.index];
            message = messageFor(result.reason);
            if (field) {
                field.setCustomValidity(message);
                field.setAttribute('aria-invalid', 'true');
                field.classList.add('is-invalid');
            }
            error.textContent = message;
            error.classList.add('is-visible');
            if (report && field && field.reportValidity) {
                field.reportValidity();
            }
            return false;
        }

        function showEmptyLastRow(report) {
            var fields = inputs();
            var field = fields[fields.length - 1];
            var message = messageFor('empty');
            clearErrors();
            field.setCustomValidity(message);
            field.setAttribute('aria-invalid', 'true');
            field.classList.add('is-invalid');
            error.textContent = message;
            error.classList.add('is-visible');
            if (report && field.reportValidity) {
                field.reportValidity();
            }
        }

        function createRow() {
            var reference = rows.querySelector('[data-vx-custom-domain-row]');
            var row = reference.cloneNode(true);
            var input = row.querySelector('[data-vx-custom-domain-input]');
            input.value = '';
            input.setCustomValidity('');
            input.removeAttribute('aria-invalid');
            input.classList.remove('is-invalid');
            rows.appendChild(row);
            refreshControls();
            input.focus();
        }

        rows.addEventListener('click', function (event) {
            var add = event.target.closest ? event.target.closest('[data-vx-custom-domain-add]') : null;
            var remove = event.target.closest ? event.target.closest('[data-vx-custom-domain-remove]') : null;
            var row;

            if (add && rows.contains(add)) {
                if (!normalizeDomain(values()[inputs().length - 1])) {
                    showEmptyLastRow(true);
                } else if (validate(true) && inputs().length < max) {
                    createRow();
                }
                return;
            }
            if (remove && rows.contains(remove)) {
                row = remove.closest('[data-vx-custom-domain-row]');
                if (row && inputs().length > 1) {
                    rows.removeChild(row);
                } else if (row) {
                    row.querySelector('[data-vx-custom-domain-input]').value = '';
                }
                refreshControls();
                validate(false);
                sync(true);
            }
        });

        rows.addEventListener('input', function (event) {
            if (event.target.hasAttribute('data-vx-custom-domain-input')) {
                refreshControls();
                validate(false);
                sync(true);
            }
        });

        rows.addEventListener('focusout', function (event) {
            if (event.target.hasAttribute('data-vx-custom-domain-input')) {
                event.target.value = normalizeDomain(event.target.value);
                validate(false);
                sync(true);
            }
        });

        form.addEventListener('submit', function (event) {
            if (!validate(true)) {
                event.preventDefault();
                return;
            }
            sync(false);
        }, true);

        refreshControls();
        validate(false);
        sync(false);
    }

    function initAll() {
        var components = document.querySelectorAll('[data-vx-custom-domains]');
        var i;
        for (i = 0; i < components.length; i += 1) {
            initComponent(components[i]);
        }
    }

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initAll);
        } else {
            initAll();
        }
    }

    return {
        normalizeDomain: normalizeDomain,
        isValidDomain: isValidDomain,
        serializeDomains: serializeDomains,
        validateDomains: validateDomains
    };
}));
