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
    }

    function updateSummary(metrics, healthSummaries, alerts) {
        var cpuTotal = 0;
        var memTotal = 0;
        var rxTotal = 0;
        var txTotal = 0;
        var cpuCount = 0;
        var healthLabel = 'No data';
        var healthUpdated = 'No data';

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
            }
            if (metric.LATEST.RX_MBPS !== null) {
                rxTotal += metric.LATEST.RX_MBPS;
            }
            if (metric.LATEST.TX_MBPS !== null) {
                txTotal += metric.LATEST.TX_MBPS;
            }
        });

        if (healthSummaries.length > 0) {
            healthLabel = healthSummaries[0].HEALTH_STATUS || 'unknown';
            healthUpdated = healthSummaries[0].LAST_HEALTH_AT || 'No data';
        }

        $('#docker-card-cpu').text(cpuCount ? formatMetric(cpuTotal.toFixed(1), '%') : 'No data');
        $('#docker-card-mem').text(metrics.length ? formatMetric(memTotal.toFixed(1), ' MB') : 'No data');
        $('#docker-card-rx').text(metrics.length ? formatMetric(rxTotal.toFixed(2), ' MB/s') : 'No data');
        $('#docker-card-tx').text(metrics.length ? formatMetric(txTotal.toFixed(2), ' MB/s') : 'No data');
        $('#docker-card-health-status').text(healthLabel);
        $('#docker-card-health-updated').text(healthUpdated);
        $('#docker-card-alert-count').text(alerts.length);
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

            article.append('<p><b>' + alert.TITLE + '</b> (' + alert.LEVEL + ')</p>');
            article.append('<p>' + alert.MESSAGE + '</p>');
            article.append('<p>Container: <b>' + alert.NAME + '</b> / Owner: <b>' + alert.OWNER + '</b></p>');
            article.append('<p>Status: <b>' + alert.STATUS + '</b> / Ack: <b>' + alert.ACK + '</b> / Last seen: <b>' + alert.LAST_SEEN + '</b></p>');

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
