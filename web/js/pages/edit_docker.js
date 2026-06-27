(function($) {
    if (!window.DOCKER_EDIT) {
        return;
    }

    var config = window.DOCKER_EDIT;
    var activeAlert = null;
    var acknowledgeButton = $('#docker-alert-acknowledge');

    function postJson(url, payload, callback) {
        $.ajax({
            url: url,
            type: 'POST',
            dataType: 'json',
            data: payload
        }).done(function(response) {
            callback(response || null);
        }).fail(function() {
            callback(null);
        });
    }

    function renderSeries(target, series, suffix) {
        var node = $(target);
        if (!series || series.length === 0) {
            node.text('No metrics available yet.');
            return;
        }

        var lines = [];
        $.each(series, function(_, point) {
            lines.push(point.TS + '  ' + point.VALUE + suffix);
        });

        node.empty().append(
            $('<pre/>', {
                style: 'white-space: pre-wrap;'
            }).text(lines.join("\n"))
        );
    }

    function refreshMetrics() {
        postJson(config.statsUrl, {
            token: config.token,
            owner: config.owner,
            name: config.name,
            period: '5m'
        }, function(metric) {
            if (!metric) {
                $('#docker-chart-cpu, #docker-chart-mem, #docker-chart-rx, #docker-chart-tx').text('No metrics available yet.');
                return;
            }

            renderSeries('#docker-chart-cpu', metric.CPU_PCT, '%');
            renderSeries('#docker-chart-mem', metric.MEM_MB, ' MB');
            renderSeries('#docker-chart-rx', metric.RX_MBPS, ' MB/s');
            renderSeries('#docker-chart-tx', metric.TX_MBPS, ' MB/s');
        });

        postJson(config.healthUrl, {
            token: config.token,
            owner: config.owner,
            name: config.name
        }, function(health) {
            if (!health) {
                return;
            }

            $('#docker-detail-status').text(health.STATUS || 'No data');
            $('#docker-detail-health-status').text(health.HEALTH_STATUS || 'unknown');
            $('#docker-detail-health-updated').text(health.LAST_HEALTH_AT || 'No data');
        });
    }

    function renderAlerts(alerts) {
        var panelBody = $('#docker-alerts-panel .docker-alerts-list');
        panelBody.empty();
        activeAlert = null;

        if (!alerts || alerts.length === 0) {
            panelBody.append('<div class="docker-alerts-empty">No Docker alerts are active for this container.</div>');
            acknowledgeButton.hide();
            return;
        }

        $.each(alerts, function(_, alert) {
            var article = $('<article/>', {
                id: 'docker-alert-' + alert.OWNER + '-' + alert.AID,
                'data-owner': alert.OWNER,
                'data-aid': alert.AID
            });

            article.append(
                $('<p/>')
                    .append($('<b/>').text(alert.TITLE || ''))
                    .append(document.createTextNode(' (' + (alert.LEVEL || '') + ')'))
            );
            article.append($('<p/>').text(alert.MESSAGE || ''));
            article.append(
                $('<p/>')
                    .append(document.createTextNode('Status: '))
                    .append($('<b/>').text(alert.STATUS || ''))
                    .append(document.createTextNode(' / Ack: '))
                    .append($('<b/>').text(alert.ACK || ''))
                    .append(document.createTextNode(' / Last seen: '))
                    .append($('<b/>').text(alert.LAST_SEEN || ''))
            );

            if (alert.STATUS === 'open' && alert.ACK === 'no' && activeAlert === null) {
                activeAlert = alert;
                article.append(acknowledgeButton.show());
            }

            panelBody.append(article);
        });
    }

    function refreshAlerts() {
        postJson(config.alertsUrl, {
            token: config.token,
            owner: config.owner,
            name: config.name
        }, function(response) {
            renderAlerts(response && response.ALERTS ? response.ALERTS : []);
        });
    }

    acknowledgeButton.on('click', function(evt) {
        evt.preventDefault();
        if (!activeAlert) {
            return;
        }

        postJson(config.acknowledgeUrl, {
            token: config.token,
            owner: activeAlert.OWNER,
            aid: activeAlert.AID
        }, function() {
            activeAlert = null;
            refreshAlerts();
        });
    });

    $(function() {
        refreshMetrics();
        refreshAlerts();
        window.setInterval(function() {
            refreshMetrics();
            refreshAlerts();
        }, config.pollIntervalMs);
    });
})(jQuery);
