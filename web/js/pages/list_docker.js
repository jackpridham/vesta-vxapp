(function($) {
    if (!window.DOCKER_LIST) {
        return;
    }

    var config = window.DOCKER_LIST;
    var acknowledgeButton = $('#docker-alert-acknowledge');
    var activeAlert = null;
    var pollGeneration = 0;
    var activeRequests = [];
    var navigationActive = true;

    function setHealthState(node, status, freshness) {
        if (!node || node.length === 0) {
            return;
        }
        status = status || 'unknown';
        freshness = freshness || 'unavailable';
        node.attr('data-health-state', status);
        node.attr('data-freshness', freshness);
        node.attr(
            'aria-label',
            'Health ' + status + '; observation ' + freshness
        );
    }

    function safePostJson(url, payload) {
        var settled = $.Deferred();
        var request = $.ajax({
            url: url,
            type: 'POST',
            dataType: 'json',
            data: payload,
            timeout: config.requestTimeoutMs || 10000
        });
        activeRequests.push(request);
        request.done(function(response) {
            settled.resolve(response || null);
        }).fail(function() {
            settled.resolve(null);
        });
        return settled.promise();
    }

    function cancelActiveRequests() {
        $.each(activeRequests, function(_, request) {
            if (request && request.readyState !== 4) {
                request.abort();
            }
        });
        activeRequests = [];
    }

    function formatCpu(value) {
        var numeric = Number(value);
        return Number.isFinite(numeric) ? numeric.toFixed(1) + '%' : 'No data';
    }

    function formatCapacityMiB(value) {
        var numeric = Number(value);
        if (!Number.isFinite(numeric)) {
            return 'No data';
        }
        return numeric >= 1024
            ? (numeric / 1024).toFixed(1) + ' GiB'
            : numeric.toFixed(1) + ' MiB';
    }

    function formatNetwork(value) {
        var numeric = Number(value);
        return Number.isFinite(numeric)
            ? numeric.toFixed(2) + ' MiB/s'
            : 'No data';
    }

    function formatTimestamp(value) {
        var timestamp = Date.parse(value || '');
        var seconds;
        var relative;
        if (!Number.isFinite(timestamp)) {
            return 'No data';
        }
        seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
        if (seconds < 60) {
            relative = seconds + 's ago';
        } else if (seconds < 3600) {
            relative = Math.floor(seconds / 60) + 'm ago';
        } else if (seconds < 86400) {
            relative = Math.floor(seconds / 3600) + 'h ago';
        } else {
            relative = Math.floor(seconds / 86400) + 'd ago';
        }
        return new Date(timestamp).toLocaleString() + ' (' + relative + ')';
    }

    function emptyMetric() {
        return {
            LATEST: {
                CPU_PCT: null,
                MEM_MB: null,
                RX_MBPS: null,
                TX_MBPS: null
            }
        };
    }

    function unavailableHealth() {
        return {
            HEALTH_STATUS: 'unknown',
            OBSERVED_AT: '',
            FRESHNESS: 'unavailable'
        };
    }

    function updatePrimaryState() {
        $('#docker-unavailable-state').toggle(config.primaryState === 'unavailable');
        $('#docker-empty-state').toggle(config.primaryState === 'empty');
        $('#docker-quota-reached-state').toggle(config.primaryState === 'quota');
        $('#docker-list-state').toggle(config.primaryState === 'list');
        $('#docker-health-dashboard').toggle(config.primaryState === 'list');
        $('#docker-alerts-panel').toggle(config.primaryState === 'list');
    }

    function updateSummary(results, alerts) {
        var cpuTotal = 0;
        var memTotal = 0;
        var rxTotal = 0;
        var txTotal = 0;
        var cpuCount = 0;
        var memCount = 0;
        var rxCount = 0;
        var txCount = 0;
        var healthLabel = 'unknown';
        var healthFreshness = 'unavailable';
        var healthUpdated = '';
        var alertCount = 0;
        var healthPriority = {
            unhealthy: 5,
            degraded: 4,
            starting: 3,
            unknown: 2,
            healthy: 1
        };
        var freshnessPriority = { unavailable: 3, stale: 2, fresh: 1 };
        var bestHealthScore = 0;
        var bestFreshnessScore = 0;

        $.each(results, function(_, result) {
            var latest = result.metric && result.metric.LATEST
                ? result.metric.LATEST
                : {};
            var health = result.health || unavailableHealth();
            var healthStatus = health.HEALTH_STATUS || health.STATUS || 'unknown';
            var freshness = health.FRESHNESS || 'unavailable';

            if (Number.isFinite(Number(latest.CPU_PCT))) {
                cpuTotal += Number(latest.CPU_PCT);
                cpuCount += 1;
            }
            if (Number.isFinite(Number(latest.MEM_MB))) {
                memTotal += Number(latest.MEM_MB);
                memCount += 1;
            }
            if (Number.isFinite(Number(latest.RX_MBPS))) {
                rxTotal += Number(latest.RX_MBPS);
                rxCount += 1;
            }
            if (Number.isFinite(Number(latest.TX_MBPS))) {
                txTotal += Number(latest.TX_MBPS);
                txCount += 1;
            }
            if ((healthPriority[healthStatus] || 2) > bestHealthScore) {
                bestHealthScore = healthPriority[healthStatus] || 2;
                healthLabel = healthStatus;
            }
            if ((freshnessPriority[freshness] || 3) > bestFreshnessScore) {
                bestFreshnessScore = freshnessPriority[freshness] || 3;
                healthFreshness = freshness;
            }
            if (health.OBSERVED_AT
                && (!healthUpdated || health.OBSERVED_AT > healthUpdated)) {
                healthUpdated = health.OBSERVED_AT;
            }
        });

        $.each(alerts, function(_, alert) {
            if (alert && alert.STATUS === 'open') {
                alertCount += 1;
            }
        });

        $('#docker-card-cpu').text(cpuCount ? formatCpu(cpuTotal) : 'No data');
        $('#docker-card-mem').text(
            memCount ? formatCapacityMiB(memTotal) : 'No data'
        );
        $('#docker-card-rx').text(
            rxCount ? formatNetwork(rxTotal) : 'No data'
        );
        $('#docker-card-tx').text(
            txCount ? formatNetwork(txTotal) : 'No data'
        );
        $('#docker-card-health-status').text(healthLabel);
        setHealthState(
            $('#docker-card-health-status'),
            healthLabel,
            healthFreshness
        );
        $('#docker-card-health-updated').text(formatTimestamp(healthUpdated));
        $('#docker-card-alert-count').text(alertCount);
    }

    function renderAlerts(alerts) {
        var panel = $('#docker-alerts-panel .docker-alerts-list');
        var alertCounts = {};
        panel.empty();
        activeAlert = null;
        if (!alerts || alerts.length === 0) {
            panel.append(
                '<p class="docker-alerts-empty">'
                + 'No Docker alerts are active in this scope.</p>'
            );
            acknowledgeButton.hide();
            $('.docker-card-alert-count').text('0');
            return;
        }
        $.each(alerts, function(_, alert) {
            var key = alert.OWNER + '/' + alert.NAME;
            var article;
            alertCounts[key] = (alertCounts[key] || 0)
                + (alert.STATUS === 'open' ? 1 : 0);
            article = $('<article/>', {
                id: 'docker-alert-' + alert.OWNER + '-' + alert.AID,
                'class': 'docker-alert-row',
                'data-level': alert.LEVEL || 'info',
                'data-status': alert.STATUS || 'open'
            });
            article.append(
                $('<p/>').append($('<b/>').text(alert.TITLE || ''))
            );
            article.append($('<p/>').text(alert.MESSAGE || ''));
            article.append($('<p/>').text(
                'Container: ' + (alert.NAME || '')
                + ' / Owner: ' + (alert.OWNER || '')
                + ' / Status: ' + (alert.STATUS || '')
                + ' / Ack: ' + (alert.ACK || '')
                + ' / Last seen: ' + (alert.LAST_SEEN || '')
            ));
            if (alert.STATUS === 'open'
                && alert.ACK === 'no'
                && activeAlert === null) {
                activeAlert = alert;
            }
            panel.append(article);
        });
        acknowledgeButton.toggle(activeAlert !== null);
        $('.docker-card-alert-count').each(function() {
            var card = $(this).closest('article');
            $(this).text(
                alertCounts[card.data('owner') + '/' + card.data('name')] || 0
            );
        });
    }

    function updateCard(owner, name, metric, health) {
        var card = $('#docker-card-' + owner + '-' + name);
        var latest = metric && metric.LATEST ? metric.LATEST : {};
        var observed = health || unavailableHealth();
        var status = observed.HEALTH_STATUS || observed.STATUS || 'unknown';
        var freshness = observed.FRESHNESS || 'unavailable';
        if (card.length === 0) {
            return;
        }
        card.find('.docker-card-latest-cpu').text(formatCpu(latest.CPU_PCT));
        card.find('.docker-card-latest-mem').text(
            formatCapacityMiB(latest.MEM_MB)
        );
        card.find('.docker-card-latest-rx').text(formatNetwork(latest.RX_MBPS));
        card.find('.docker-card-latest-tx').text(formatNetwork(latest.TX_MBPS));
        card.find('.docker-card-health-badge').text(status);
        setHealthState(card.find('.docker-card-health-badge'), status, freshness);
        card.find('.docker-card-health-updated').text(
            formatTimestamp(observed.OBSERVED_AT)
        );
    }

    function finishPoll(generation, results) {
        if (!navigationActive || generation !== pollGeneration) {
            return;
        }
        safePostJson(config.alertsUrl, {
            token: config.token,
            owner: config.ownerScope
        }).done(function(alertsResponse) {
            var alerts;
            if (!navigationActive || generation !== pollGeneration) {
                return;
            }
            alerts = alertsResponse && alertsResponse.ALERTS
                ? alertsResponse.ALERTS
                : [];
            renderAlerts(alerts);
            updateSummary(results, alerts);
            updatePrimaryState();
        });
    }

    function refreshAll() {
        var generation;
        var pending;
        var results = [];
        if (!config.dockerAvailable || config.containers.length === 0) {
            updatePrimaryState();
            return;
        }
        pollGeneration += 1;
        generation = pollGeneration;
        cancelActiveRequests();
        pending = config.containers.length;
        $.each(config.containers, function(_, container) {
            var statsRequest = safePostJson(config.statsUrl, {
                token: config.token,
                owner: container.owner,
                name: container.name,
                period: '5m'
            });
            var healthRequest = safePostJson(config.healthUrl, {
                token: config.token,
                owner: container.owner,
                name: container.name
            });
            $.when(statsRequest, healthRequest).done(function(metric, health) {
                var result;
                if (!navigationActive || generation !== pollGeneration) {
                    return;
                }
                result = {
                    metric: metric || emptyMetric(),
                    health: health || unavailableHealth()
                };
                results.push(result);
                updateCard(
                    container.owner,
                    container.name,
                    result.metric,
                    result.health
                );
                pending -= 1;
                if (pending === 0) {
                    finishPoll(generation, results);
                }
            });
        });
    }

    acknowledgeButton.on('click', function(evt) {
        evt.preventDefault();
        if (!activeAlert) {
            return;
        }
        safePostJson(config.acknowledgeUrl, {
            token: config.token,
            owner: activeAlert.OWNER,
            name: activeAlert.NAME,
            aid: activeAlert.AID
        }).done(function() {
            activeAlert = null;
            refreshAll();
        });
    });

    $(window).on('beforeunload pagehide', function() {
        navigationActive = false;
        pollGeneration += 1;
        cancelActiveRequests();
    });

    window.VX_DOCKER_POLLING_TEST = {
        formatCpu: formatCpu,
        formatCapacityMiB: formatCapacityMiB,
        formatNetwork: formatNetwork,
        formatTimestamp: formatTimestamp,
        refresh: refreshAll,
        cancel: cancelActiveRequests
    };

    $(function() {
        updatePrimaryState();
        refreshAll();
        window.setInterval(refreshAll, config.pollIntervalMs);
    });
})(jQuery);
