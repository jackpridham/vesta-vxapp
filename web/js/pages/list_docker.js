(function($) {
    if (!window.DOCKER_LIST) {
        return;
    }

    var config = window.DOCKER_LIST;
    var acknowledgeButton = $('#docker-alert-acknowledge');
    var activeAlert = null;

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

    function formatMetric(value, suffix) {
        if (value === null || value === undefined || value === '') {
            return 'No data';
        }

        return value + suffix;
    }

    function updatePrimaryState() {
        $('#docker-unavailable-state').toggle(config.primaryState === 'unavailable');
        $('#docker-empty-state').toggle(config.primaryState === 'empty');
        $('#docker-quota-reached-state').toggle(config.primaryState === 'quota');
        $('#docker-list-state').toggle(config.primaryState === 'list');
        $('#docker-health-dashboard').toggle(config.primaryState === 'list');
        $('#docker-alerts-panel').toggle(config.primaryState === 'list');
    }

    function updateSummary(metrics, healthSummaries, alerts) {
        var cpuTotal = 0;
        var memTotal = 0;
        var rxTotal = 0;
        var txTotal = 0;
        var cpuCount = 0;
        var memCount = 0;
        var rxCount = 0;
        var txCount = 0;
        var healthLabel = 'No data';
        var healthUpdated = 'No data';
        var alertCount = 0;
        var healthPriority = {
            unhealthy: 5,
            degraded: 4,
            starting: 3,
            unknown: 2,
            healthy: 1
        };
        var bestHealthScore = 0;

        $.each(metrics, function(_, metric) {
            if (!metric || !metric.LATEST) {
                return;
            }

            if (metric.LATEST.CPU_PCT !== null) {
                cpuTotal += metric.LATEST.CPU_PCT;
                cpuCount += 1;
            }
            if (metric.LATEST.MEM_MB !== null) {
                memTotal += metric.LATEST.MEM_MB;
                memCount += 1;
            }
            if (metric.LATEST.RX_MBPS !== null) {
                rxTotal += metric.LATEST.RX_MBPS;
                rxCount += 1;
            }
            if (metric.LATEST.TX_MBPS !== null) {
                txTotal += metric.LATEST.TX_MBPS;
                txCount += 1;
            }
        });

        $.each(healthSummaries, function(_, health) {
            var status;
            var score;

            if (!health) {
                return;
            }

            status = health.HEALTH_STATUS || 'unknown';
            score = healthPriority[status] || healthPriority.unknown;
            if (score > bestHealthScore) {
                bestHealthScore = score;
                healthLabel = status;
            }

            if (health.LAST_HEALTH_AT && (healthUpdated === 'No data' || health.LAST_HEALTH_AT > healthUpdated)) {
                healthUpdated = health.LAST_HEALTH_AT;
            }
        });

        $.each(alerts, function(_, alert) {
            if (alert && alert.STATUS === 'open') {
                alertCount += 1;
            }
        });

        $('#docker-card-cpu').text(cpuCount ? formatMetric(cpuTotal.toFixed(1), '%') : 'No data');
        $('#docker-card-mem').text(memCount ? formatMetric(memTotal.toFixed(1), ' MB') : 'No data');
        $('#docker-card-rx').text(rxCount ? formatMetric(rxTotal.toFixed(2), ' MB/s') : 'No data');
        $('#docker-card-tx').text(txCount ? formatMetric(txTotal.toFixed(2), ' MB/s') : 'No data');
        $('#docker-card-health-status').text(healthLabel);
        $('#docker-card-health-updated').text(healthUpdated);
        $('#docker-card-alert-count').text(alertCount);
    }

    function renderAlerts(alerts) {
        var panel = $('#docker-alerts-panel .docker-alerts-list');
        panel.empty();
        activeAlert = null;

        if (!alerts || alerts.length === 0) {
            panel.append('<p class="docker-alerts-empty">No Docker alerts are active in this scope.</p>');
            acknowledgeButton.hide();
            $('.docker-card-alert-count').text('0');
            return;
        }

        var alertCounts = {};
        $.each(alerts, function(_, alert) {
            var key = alert.OWNER + '/' + alert.NAME;
            alertCounts[key] = (alertCounts[key] || 0) + (alert.STATUS === 'open' ? 1 : 0);

            var article = $('<article/>', {
                id: 'docker-alert-' + alert.OWNER + '-' + alert.AID,
                'class': 'docker-alert-row',
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
                    .append(document.createTextNode('Container: '))
                    .append($('<b/>').text(alert.NAME || ''))
                    .append(document.createTextNode(' / Owner: '))
                    .append($('<b/>').text(alert.OWNER || ''))
            );
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

            panel.append(article);
        });

        $('.docker-card-alert-count').each(function() {
            var card = $(this).closest('article');
            var key = card.data('owner') + '/' + card.data('name');
            $(this).text(alertCounts[key] || 0);
        });
    }

    function updateCard(owner, name, metric, health) {
        var card = $('#docker-card-' + owner + '-' + name);
        if (card.length === 0) {
            return;
        }

        card.find('.docker-card-latest-cpu').text(metric && metric.LATEST ? formatMetric(metric.LATEST.CPU_PCT, '%') : 'No data');
        card.find('.docker-card-latest-mem').text(metric && metric.LATEST ? formatMetric(metric.LATEST.MEM_MB, ' MB') : 'No data');
        card.find('.docker-card-latest-rx').text(metric && metric.LATEST ? formatMetric(metric.LATEST.RX_MBPS, ' MB/s') : 'No data');
        card.find('.docker-card-latest-tx').text(metric && metric.LATEST ? formatMetric(metric.LATEST.TX_MBPS, ' MB/s') : 'No data');
        card.find('.docker-card-health-badge').text(health ? (health.HEALTH_STATUS || 'unknown') : 'No data');
        card.find('.docker-card-health-updated').text(health && health.LAST_HEALTH_AT ? health.LAST_HEALTH_AT : 'No data');
    }

    function refreshAll() {
        if (!config.dockerAvailable || config.containers.length === 0) {
            updatePrimaryState();
            return;
        }

        var pending = config.containers.length;
        var metrics = [];
        var healthSummaries = [];

        $.each(config.containers, function(_, container) {
            postJson(config.statsUrl, {
                token: config.token,
                owner: container.owner,
                name: container.name,
                period: '5m'
            }, function(metric) {
                postJson(config.healthUrl, {
                    token: config.token,
                    owner: container.owner,
                    name: container.name
                }, function(health) {
                    metrics.push(metric || { LATEST: { CPU_PCT: null, MEM_MB: null, RX_MBPS: null, TX_MBPS: null } });
                    if (health) {
                        healthSummaries.push(health);
                    }
                    updateCard(container.owner, container.name, metric, health);
                    pending -= 1;

                    if (pending === 0) {
                        postJson(config.alertsUrl, {
                            token: config.token,
                            owner: config.ownerScope
                        }, function(alertsResponse) {
                            var alerts = alertsResponse && alertsResponse.ALERTS ? alertsResponse.ALERTS : [];
                            renderAlerts(alerts);
                            updateSummary(metrics, healthSummaries, alerts);
                            updatePrimaryState();
                        });
                    }
                });
            });
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
            refreshAll();
        });
    });

    $(function() {
        updatePrimaryState();
        refreshAll();
        window.setInterval(refreshAll, config.pollIntervalMs);
    });
})(jQuery);
