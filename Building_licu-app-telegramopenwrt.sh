#!/bin/sh
# ============================================================================
# Сборка luci-app-telegramopenwrt и luci-i18n-telegramopenwrt-ru  (v2.2)
# https://github.com/alexwbaule/telegramopenwrt
#
# Зависимости на хосте: curl gcc coreutils
#
# Исправления v2.2:
#   • Статус службы определяется по наличию процесса (get_pid),
#     а не по /etc/init.d/telegram_bot status — это устраняет
#     рассинхрон кнопок Запустить/Перезапустить/Остановить
#   • Увеличены задержки ожидания после restart (1500 мс, как в эталоне)
#   • Кнопка «Копировать» в логах: добавлен фоллбэк через execCommand
#   • Карточка статуса упрощена — убрана таблица параметров процесса
#   • Добавлен редактор файла игнорируемых MAC-адресов
#   • Добавлено предупреждение о захардкоженных настройках прокси
# ============================================================================

telegramopenwrtLuciSource="telegramopenwrtLuciSource"
telegramopenwrtI18nSource="telegramopenwrtI18nSource"
PKG_VERSION="2.2"
PKG_RELEASE="1"
SOURCE_DATE_EPOCH="$(date +%s)"

UpdateScript()
{
echo "Происходит загрузка скрипта для сборки ipk пакета ipkg-build, подождите…"
curl -Ls -O "https://github.com/openwrt/openwrt/raw/refs/heads/main/scripts/ipkg-build"
chmod +x ./ipkg-build
echo "Скрипт ipkg-build загружен"
}

# ============================================================================
# Пакет LuCI
# ============================================================================
compileTelegramopenwrtLuci()
{
# ---------------- rpcd-плагин ----------------
mkdir -p "$telegramopenwrtLuciSource"/usr/libexec/rpcd/
cat << 'RPCEOF' > "$telegramopenwrtLuciSource"/usr/libexec/rpcd/telegramopenwrt
#!/bin/sh
# rpcd-плагин для управления telegram_bot (telegramopenwrt)
# Совместим с BusyBox / ash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /usr/share/libubox/jshn.sh

INIT_SCRIPT="/etc/init.d/telegram_bot"
UCI_CONF="telegramopenwrt"
PROG="/sbin/telegram_bot"
MAC_IGNORE_FILE="/etc/telegramopenwrt/macaddr.ignore"
MAX_FILE=262144

json_error() {
	json_init
	json_add_boolean ok 0
	json_add_string error "$1"
	json_dump
	exit 0
}

is_num() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# ============================================================================
# Поиск PID. ВАЖНО: используем тот же метод, что и оригинальный
# init-скрипт (pgrep -f ${PROG}), чтобы результат совпадал.
# ============================================================================
get_pid() {
	local pid p
	# Способ 1: pgrep — ровно как в /etc/init.d/telegram_bot
	if command -v pgrep >/dev/null 2>&1; then
		pid="$(pgrep -f "$PROG" 2>/dev/null | head -n1)"
		if [ -n "$pid" ]; then
			printf '%s' "$pid"
			return
		fi
	fi
	# Способ 2: /proc/*/cmdline
	for p in /proc/[0-9]*/cmdline; do
		[ -e "$p" ] || continue
		if tr '\000' ' ' < "$p" 2>/dev/null | grep -q "/sbin/telegram_bot"; then
			pid="${p#/proc/}"
			pid="${pid%%/*}"
			printf '%s' "$pid"
			return
		fi
	done
	# Способ 3: /proc/*/comm (скрипт бота делает:
	#   echo -n "telegram_bot" >/proc/$$/comm)
	for p in /proc/[0-9]*/comm; do
		[ -e "$p" ] || continue
		if [ "$(cat "$p" 2>/dev/null)" = "telegram_bot" ]; then
			pid="${p#/proc/}"
			pid="${pid%%/*}"
			printf '%s' "$pid"
			return
		fi
	done
	printf ''
}

# ============================================================================
# Инфо о процессе (для карточки)
# ============================================================================
get_process_info() {
	local pid uid user cmdline rss rest starttime upt hz proc_uptime
	pid=$(get_pid)
	if [ -z "$pid" ] || [ ! -r "/proc/$pid/stat" ]; then
		printf ''
		return
	fi
	uid=$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	user=$(awk -F: -v u="$uid" '$3==u{print $1;exit}' /etc/passwd 2>/dev/null)
	[ -n "$user" ] || user="${uid:-unknown}"
	cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
	rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)
	rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
	starttime=$(printf '%s' "$rest" | awk '{print $20}')
	upt=$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null)
	hz=100
	starttime=${starttime:-0}
	upt=${upt:-0}
	proc_uptime=$((upt - starttime / hz))
	[ "$proc_uptime" -lt 0 ] && proc_uptime=0
	printf "%s|%s|%s|%s|%s" \
		"$pid" "$user" "${rss:-0}" "$proc_uptime" "$cmdline"
}

# ============================================================================
# RPC: status
# КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: статус определяется по фактическому наличию
# процесса (get_pid), а не по `$INIT_SCRIPT status`, потому что
# оригинальный stop_service() убивает процесс напрямую через kill,
# и procd-статус может рассинхронизироваться.
# ============================================================================
method_status() {
	local running=0 enabled=0 pid
	if [ -x "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" enabled >/dev/null 2>&1 && enabled=1
	fi
	pid="$(get_pid)"
	[ -n "$pid" ] && running=1
	json_init
	json_add_boolean ok 1
	json_add_boolean running "$running"
	json_add_boolean enabled "$enabled"
	[ -n "$pid" ] && json_add_int pid "$pid"
	json_dump
}

# ============================================================================
# RPC: service
# ============================================================================
method_service() {
	local action="$1" rc=1
	if [ ! -x "$INIT_SCRIPT" ]; then
		json_error "init script not found: $INIT_SCRIPT"
	fi
	case "$action" in
		start|stop|restart|enable|disable)
			"$INIT_SCRIPT" "$action" >/dev/null 2>&1
			rc=$?
			;;
		*)
			json_error "unsupported action: $action"
			;;
	esac
	json_init
	json_add_boolean ok "$([ $rc -eq 0 ] && echo 1 || echo 0)"
	json_add_int rc "$rc"
	json_dump
}

# ============================================================================
# RPC: load (то же исправление определения статуса)
# ============================================================================
method_load() {
	local running=0 enabled=0 pid raw
	if [ -x "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" enabled >/dev/null 2>&1 && enabled=1
	fi
	pid="$(get_pid)"
	[ -n "$pid" ] && running=1
	raw="$(get_process_info)"
	json_init
	json_add_boolean ok 1
	json_add_object service
	json_add_boolean running "$running"
	json_add_boolean enabled "$enabled"
	[ -n "$pid" ] && json_add_int pid "$pid"
	json_close_object
	json_add_object proc
	if [ -n "$raw" ]; then
		json_add_boolean available 1
		local OLD_IFS="$IFS"
		IFS="|"
		set -- $raw
		IFS="$OLD_IFS"
		json_add_int pid "${1:-0}"
		json_add_string user "${2:-unknown}"
		json_add_int rss_kb "${3:-0}"
		json_add_int uptime_sec "${4:-0}"
		json_add_string cmdline "${5:-}"
	else
		json_add_boolean available 0
	fi
	json_close_object
	json_dump
}

# ============================================================================
# RPC: test_bot
# ============================================================================
method_test_bot() {
	local token url result rc ok username bot_id error fetch_cmd
	token="$(uci -q get "${UCI_CONF}.global.key" 2>/dev/null)"
	url="$(uci -q get "${UCI_CONF}.global.url" 2>/dev/null)"
	[ -n "$url" ] || url="https://api.telegram.org"
	url="${url%/}"

	json_init
	json_add_boolean ok 1

	if [ -z "$token" ] || [ "$token" = "[PUT YOUR BOT KEY HERE]" ]; then
		json_add_boolean bot_ok 0
		json_add_string error "Bot token is not configured"
		json_dump
		return
	fi

	if command -v curl >/dev/null 2>&1; then
		fetch_cmd="curl"
	elif command -v wget >/dev/null 2>&1; then
		fetch_cmd="wget"
	else
		json_add_boolean bot_ok 0
		json_add_string error "Neither curl nor wget is available"
		json_dump
		return
	fi

	if [ "$fetch_cmd" = "curl" ]; then
		result="$(curl -s -m 15 "${url}/bot${token}/getMe" 2>/dev/null)"
		rc=$?
	else
		result="$(wget -q -O - -T 15 "${url}/bot${token}/getMe" 2>/dev/null)"
		rc=$?
	fi

	if [ $rc -ne 0 ]; then
		json_add_boolean bot_ok 0
		json_add_string error "Connection failed (rc=$rc). Check internet and API URL."
		json_dump
		return
	fi

	if ! command -v jsonfilter >/dev/null 2>&1; then
		json_add_boolean bot_ok 0
		json_add_string error "jsonfilter not available"
		json_dump
		return
	fi

	ok="$(printf '%s' "$result" | jsonfilter -e '@.ok' 2>/dev/null)"
	if [ "$ok" = "true" ]; then
		username="$(printf '%s' "$result" | jsonfilter -e '@.result.username' 2>/dev/null)"
		bot_id="$(printf '%s' "$result" | jsonfilter -e '@.result.id' 2>/dev/null)"
		json_add_boolean bot_ok 1
		json_add_string username "${username:-unknown}"
		[ -n "$bot_id" ] && json_add_int bot_id "$bot_id"
	else
		error="$(printf '%s' "$result" | jsonfilter -e '@.description' 2>/dev/null)"
		[ -n "$error" ] || error="Unknown API error"
		json_add_boolean bot_ok 0
		json_add_string error "$error"
	fi
	json_dump
}

# ============================================================================
# RPC: log_tail (Live Tail)
# ============================================================================
method_log_tail() {
	local lines="$1" content count=0
	is_num "$lines" || lines=300
	[ "$lines" -lt 1 ] && lines=1
	[ "$lines" -gt 2000 ] && lines=2000
	content="$(logread -e "telegram_bot" 2>/dev/null | tail -n "$lines")"
	if [ -n "$content" ]; then
		count="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"
	fi
	json_init
	json_add_boolean ok 1
	json_add_string content "$content"
	json_add_int lines "$count"
	json_dump
}

# ============================================================================
# RPC: check_tools
# ============================================================================
method_check_tools() {
	json_init
	json_add_boolean ok 1
	command -v curl >/dev/null 2>&1 && json_add_boolean curl 1 || json_add_boolean curl 0
	command -v jsonfilter >/dev/null 2>&1 && json_add_boolean jsonfilter 1 || json_add_boolean jsonfilter 0
	if [ -d /etc/ssl/certs ] || [ -f /etc/ssl/certs/ca-certificates.crt ]; then
		json_add_boolean ca_bundle 1
	else
		json_add_boolean ca_bundle 0
	fi
	json_dump
}

# ============================================================================
# RPC: file_read / file_write — только для разрешённых файлов
# (аналогично эталонному TorrServer: белый список путей)
# ============================================================================
allowed_file() {
	local name="$1"
	case "$name" in
		macignore) printf '%s' "$MAC_IGNORE_FILE" ;;
		*) return 1 ;;
	esac
}

method_file_read() {
	local name="$1" f size content
	[ -n "$name" ] || json_error "name required"
	f="$(allowed_file "$name")" || json_error "unknown or denied file"
	if [ ! -f "$f" ]; then
		json_init
		json_add_boolean ok 1
		json_add_boolean exists 0
		json_add_string content ""
		json_dump
		return
	fi
	size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
	is_num "$size" || size=0
	[ "$size" -le "$MAX_FILE" ] || json_error "file too large"
	content="$(cat "$f"; printf x)"
	content="${content%x}"
	json_init
	json_add_boolean ok 1
	json_add_boolean exists 1
	json_add_int size "$size"
	json_add_string content "$content"
	json_dump
}

method_file_write() {
	local name="$1" content="$2" f dir
	[ -n "$name" ] || json_error "name required"
	f="$(allowed_file "$name")" || json_error "file is not writable"
	dir="${f%/*}"
	[ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || json_error "cannot create directory"
	printf '%s' "$content" > "$f" || json_error "write failed"
	json_init
	json_add_boolean ok 1
	json_add_string path "$f"
	json_dump
}

# ============================================================================
# Диспетчер
# ============================================================================
case "$1" in
	list)
		cat << 'LISTEOF'
{
	"status": {},
	"service": {"action": "string"},
	"load": {},
	"test_bot": {},
	"log_tail": {"lines": "int"},
	"check_tools": {},
	"file_read": {"name": "string"},
	"file_write": {"name": "string", "content": "string"}
}
LISTEOF
	;;
	call)
		method="$2"
		ACTION=""
		LINES=""
		NAME=""
		CONTENT=""
		json_input="$(cat)"
		if [ -n "$json_input" ]; then
			json_load "$json_input" 2>/dev/null
			json_get_var ACTION action
			json_get_var LINES lines
			json_get_var NAME name
			json_get_var CONTENT content
		fi
		case "$method" in
			status)      method_status ;;
			service)     method_service "$ACTION" ;;
			load)        method_load ;;
			test_bot)    method_test_bot ;;
			log_tail)    method_log_tail "$LINES" ;;
			check_tools) method_check_tools ;;
			file_read)   method_file_read "$NAME" ;;
			file_write)  method_file_write "$NAME" "$CONTENT" ;;
			*)           json_error "unknown method: $method" ;;
		esac
	;;
	*)
		exit 1
	;;
esac
RPCEOF
chmod +x "$telegramopenwrtLuciSource/usr/libexec/rpcd/telegramopenwrt"

# ---------------- JavaScript view ----------------
mkdir -p "$telegramopenwrtLuciSource"/www/luci-static/resources/view/
cat << 'JSEOF' > "$telegramopenwrtLuciSource"/www/luci-static/resources/view/telegramopenwrt.js
'use strict';
'require view';
'require form';
'require ui';
'require uci';
'require poll';
'require rpc';

var callTGStatus = rpc.declare({
	object: 'telegramopenwrt', method: 'status', expect: {}
});
var callTGService = rpc.declare({
	object: 'telegramopenwrt', method: 'service', params: ['action'], expect: {}
});
var callTGLoad = rpc.declare({
	object: 'telegramopenwrt', method: 'load', expect: {}
});
var callTGTestBot = rpc.declare({
	object: 'telegramopenwrt', method: 'test_bot', expect: {}
});
var callTGLogTail = rpc.declare({
	object: 'telegramopenwrt', method: 'log_tail', params: ['lines'], expect: {}
});
var callTGCheckTools = rpc.declare({
	object: 'telegramopenwrt', method: 'check_tools', expect: {}
});
var callTGFileRead = rpc.declare({
	object: 'telegramopenwrt', method: 'file_read', params: ['name'], expect: {}
});
var callTGFileWrite = rpc.declare({
	object: 'telegramopenwrt', method: 'file_write', params: ['name', 'content'], expect: {}
});

function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;')
		.replace(/>/g, '&gt;').replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}
function setEl(id, text) {
	var el = document.getElementById(id);
	if (el) el.textContent = text;
}
function injectStyle() {
	if (document.getElementById('tg-style')) return;
	var st = document.createElement('style');
	st.id = 'tg-style';
	st.textContent =
		'#tg-card{padding:12px 15px;border-radius:4px;transition:background .4s,border-color .4s;}' +
		'.tg-cmd-table td{padding:6px 10px;}' +
		'.tg-cmd-table code{background:#e9ecef;padding:2px 6px;border-radius:3px;font-size:.85em;}' +
		'.tg-log-pre{height:60vh;min-height:300px;overflow:auto;background:#1e1e1e;color:#d4d4d4;' +
		'padding:15px;font-family:monospace;white-space:pre;word-break:keep-all;' +
		'font-size:.85em;border:1px solid #444;border-radius:4px;margin:0;}' +
		'.tg-log-status{font-size:.85em;margin-bottom:8px;padding:6px 10px;background:#f5f5f5;' +
		'border:1px solid #ddd;border-radius:4px;color:#666;}' +
		'.tg-log-status .dot{display:inline-block;width:8px;height:8px;border-radius:50%;' +
		'margin-right:6px;vertical-align:middle;}';
	document.head.appendChild(st);
}

function tgSelectNode(node) {
	if (!node) return;
	try {
		var range = document.createRange();
		range.selectNodeContents(node);
		var sel = window.getSelection();
		sel.removeAllRanges();
		sel.addRange(range);
	} catch (e) {}
}
function tgCopyNode(node) {
	if (!node) return;
	var text = node.textContent || '';
	var done = function() {
		ui.addNotification(null, E('p', _('Log copied to clipboard.')));
	};
	var fallback = function() {
		try {
			tgSelectNode(node);
			var ok = document.execCommand('copy');
			if (ok) {
				done();
			} else {
				ui.addNotification(null, E('p', _('Copy failed. Please select text manually.')));
			}
		} catch (e) {
			ui.addNotification(null, E('p', _('Copy failed. Please select text manually.')));
		}
	};
	if (window.navigator && navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(text).then(done).catch(fallback);
	} else {
		fallback();
	}
}

function waitForState(expectRunning, initialDelay, maxWait) {
	initialDelay = initialDelay || 0;
	maxWait = maxWait || 12000;
	return new Promise(function(resolve) {
		var started = Date.now();
		function check() {
			callTGStatus().then(function(res) {
				var running = !!(res && res.ok && res.running);
				if (running === expectRunning || (Date.now() - started) > maxWait) {
					resolve(running);
				} else {
					window.setTimeout(check, 600);
				}
			}).catch(function() {
				if ((Date.now() - started) > maxWait) resolve(false);
				else window.setTimeout(check, 600);
			});
		}
		window.setTimeout(check, initialDelay);
	});
}

var _statusFetching = false;
function updateStatusCard() {
	if (_statusFetching) return Promise.resolve();
	_statusFetching = true;
	return callTGLoad().then(function(res) {
		_statusFetching = false;
		if (!res || !res.ok) return;
		var service = res.service || {};
		var running = !!service.running;
		var enabled = !!service.enabled;

		var card = document.getElementById('tg-card');
		var st = document.getElementById('tg-state');
		if (running) {
			if (card) { card.style.background = '#e8f5e9'; card.style.borderLeftColor = '#28a745'; }
			if (st) { st.style.color = '#28a745'; st.textContent = '▶ ' + _('Running'); }
		} else {
			if (card) { card.style.background = '#ffebee'; card.style.borderLeftColor = '#dc3545'; }
			if (st) { st.style.color = '#dc3545'; st.textContent = '⏸ ' + _('Stopped'); }
		}

		var btnStart = document.getElementById('cbid.telegramopenwrt.global._btn_start');
		var btnStop = document.getElementById('cbid.telegramopenwrt.global._btn_stop');
		var btnRestart = document.getElementById('cbid.telegramopenwrt.global._btn_restart');
		var btnAutoEn = document.getElementById('cbid.telegramopenwrt.global._btn_autostart_enable');
		var btnAutoDis = document.getElementById('cbid.telegramopenwrt.global._btn_autostart_disable');
		if (btnStart) { var r = btnStart.closest('.cbi-value'); if (r) r.style.display = running ? 'none' : ''; }
		if (btnStop) { var r2 = btnStop.closest('.cbi-value'); if (r2) r2.style.display = running ? '' : 'none'; }
		if (btnRestart) { var r3 = btnRestart.closest('.cbi-value'); if (r3) r3.style.display = running ? '' : 'none'; }
		if (btnAutoEn) { var r4 = btnAutoEn.closest('.cbi-value'); if (r4) r4.style.display = enabled ? 'none' : ''; }
		if (btnAutoDis) { var r5 = btnAutoDis.closest('.cbi-value'); if (r5) r5.style.display = enabled ? '' : 'none'; }
	}).catch(function() { _statusFetching = false; });
}

var LOG_TAIL_LINES = 300;
var LOG_TAIL_INTERVAL = 2;
var LOG_SOURCE = 'logread -e telegram_bot';

var _logTailTimer = null;
var _logTailActive = false;
var _logTailPaused = false;
var _logTailEls = null;

function logTailCleanup() {
	if (_logTailTimer) {
		window.clearInterval(_logTailTimer);
		_logTailTimer = null;
	}
	_logTailActive = false;
	_logTailPaused = false;
	_logTailEls = null;
}

function updateLogTailStatus() {
	if (!_logTailEls) return;
	var els = _logTailEls;
	if (!_logTailActive) {
		els.statusText.textContent = _('Live tail stopped');
		els.dot.style.background = '#999';
		els.btnToggle.textContent = _('Start Live Tail');
	} else if (_logTailPaused) {
		els.statusText.textContent = _('Live tail paused');
		els.dot.style.background = '#ffc107';
		els.btnToggle.textContent = _('Start Live Tail');
	} else {
		els.statusText.textContent = _('Live tail active - updating every 2 seconds');
		els.dot.style.background = '#28a745';
		els.btnToggle.textContent = _('Stop Live Tail');
	}
}

function fetchLogTail() {
	if (!_logTailEls || !_logTailActive || _logTailPaused) return Promise.resolve();
	if (!document.body.contains(_logTailEls.pre)) {
		logTailCleanup();
		return Promise.resolve();
	}
	var els = _logTailEls;
	var atBottom = (els.pre.scrollHeight - els.pre.scrollTop - els.pre.clientHeight) < 40;

	return callTGLogTail(LOG_TAIL_LINES).then(function(res) {
		if (!_logTailEls || !document.body.contains(els.pre)) { logTailCleanup(); return; }
		if (!res || !res.ok) {
			els.error.textContent = _('Failed to read system log: ') + (res && res.error ? res.error : _('Unknown error'));
			return;
		}
		els.error.textContent = '';
		var content = res.content || '';
		if (!content.trim()) {
			els.pre.textContent = _('No telegram_bot entries found in system log. Make sure the service has been started at least once.');
			els.pre.style.color = '#888';
		} else {
			els.pre.textContent = content;
			els.pre.style.color = '#d4d4d4';
			if (atBottom) els.pre.scrollTop = els.pre.scrollHeight;
		}
		els.count.textContent = (res.lines || 0) + ' ' + _('lines');
	}).catch(function(err) {
		if (!_logTailEls || !document.body.contains(els.pre)) return;
		els.error.textContent = _('Failed to read system log: ') + (err && err.message ? err.message : _('Unknown error'));
	});
}

function startLogTail() {
	if (_logTailTimer) window.clearInterval(_logTailTimer);
	_logTailActive = true;
	_logTailPaused = false;
	_logTailTimer = window.setInterval(fetchLogTail, LOG_TAIL_INTERVAL * 1000);
	updateLogTailStatus();
	return fetchLogTail();
}

function stopLogTail() {
	if (_logTailTimer) {
		window.clearInterval(_logTailTimer);
		_logTailTimer = null;
	}
	_logTailActive = false;
	_logTailPaused = false;
	updateLogTailStatus();
}

function toggleLogTail() {
	if (_logTailActive && !_logTailPaused) stopLogTail();
	else startLogTail();
}

function handleLogTailVisibility() {
	if (!_logTailEls) return;
	if (document.hidden) {
		if (_logTailActive && _logTailTimer) {
			window.clearInterval(_logTailTimer);
			_logTailTimer = null;
			_logTailPaused = true;
			updateLogTailStatus();
		}
	} else if (_logTailActive && _logTailPaused) {
		_logTailPaused = false;
		_logTailTimer = window.setInterval(fetchLogTail, LOG_TAIL_INTERVAL * 1000);
		updateLogTailStatus();
		fetchLogTail();
	}
}

function openLogTail() {
	logTailCleanup();

	var dot = E('span', { 'class': 'dot' });
	var statusText = E('span');
	var count = E('span', { style: 'float:right;color:#888;' });
	var statusLine = E('div', { 'class': 'tg-log-status' }, [
		dot, statusText,
		E('span', { style: 'margin-left:10px;color:#888;' }, _('Source: ') + LOG_SOURCE),
		count
	]);
	var errorLine = E('div', { style: 'font-size:.85em;color:#dc3545;margin-top:6px;' });
	var pre = E('pre', { 'class': 'tg-log-pre' }, _('Loading…'));

	var btnToggle = E('button', { 'class': 'btn cbi-button-action', style: 'margin-right:6px;' }, _('Stop Live Tail'));
	var btnCopy = E('button', { 'class': 'btn', style: 'margin-right:6px;' }, _('Copy'));
	var btnClose = E('button', { 'class': 'btn' }, _('Close'));

	_logTailEls = {
		pre: pre, dot: dot, statusText: statusText, count: count,
		error: errorLine, btnToggle: btnToggle
	};

	btnToggle.addEventListener('click', toggleLogTail);
	btnCopy.addEventListener('click', function() { tgCopyNode(pre); });
	btnClose.addEventListener('click', function() {
		logTailCleanup();
		ui.hideModal();
	});

	ui.showModal(_('Telegram Bot Log — Live Tail'), [
		statusLine, pre, errorLine,
		E('div', { 'class': 'right', style: 'margin-top:10px' }, [btnToggle, btnCopy, btnClose])
	]);

	return startLogTail();
}

function openFileEditor(name, title, warningText, defaultContent) {
	return callTGFileRead(name).then(function(res) {
		if (!res || !res.ok) {
			ui.addNotification(null, E('p', _('Failed to read file: ') + (res && res.error ? res.error : 'unknown error')));
			return;
		}
		var content = res.exists ? res.content : (defaultContent !== undefined ? defaultContent : '');
		var textarea = E('textarea', {
			style: 'width:100%; height:400px; font-family:monospace; padding:10px; box-sizing:border-box;',
			rows: 20
		}, content || '');

		var elements = [];
		if (warningText) {
			elements.push(E('div', { 'class': 'alert-message warning' }, warningText));
		}
		if (!res.exists && defaultContent !== undefined) {
			elements.push(E('p', { style: 'color:#28a745;' }, _('File does not exist yet. It will be created when you save.')));
		}
		elements.push(textarea);
		elements.push(E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function() {
					callTGFileWrite(name, textarea.value).then(function(wres) {
						if (!wres || !wres.ok) {
							ui.addNotification(null, E('p', _('Failed to save: ') + (wres && wres.error ? wres.error : 'unknown error')));
							return;
						}
						ui.addNotification(null, E('p', _('File saved successfully!')));
						ui.hideModal();
					});
				}
			}, _('Save')),
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel'))
		]));
		ui.showModal(title, elements);
	});
}

var botCommands = [
	{cmd:'/start',desc:'Display help menu',cat:'general'},
	{cmd:'/cam_movie',desc:'Record 25 seconds of a camIP and send it',cat:'camera'},
	{cmd:'/cam_mv',desc:'Move the camera around',cat:'camera'},
	{cmd:'/cam_shot',desc:'Get a picture from the camera',cat:'camera'},
	{cmd:'/cam_vdo',desc:'Get a 25 seconds recording from a camIP',cat:'camera'},
	{cmd:'/chromego_add',desc:'Include a word to be blocked in ChromeGo permissions',cat:'chromego'},
	{cmd:'/chromego_del',desc:'Remove a word from ChromeGo permissions',cat:'chromego'},
	{cmd:'/chromego_list',desc:'List all ChromeGo permissions',cat:'chromego'},
	{cmd:'/fw_add',desc:'Block a hostname using a deny rule in the firewall (optional: hours 23:00\u201308:00)',cat:'firewall'},
	{cmd:'/fw_delete',desc:'Remove a hostname from a deny firewall rule',cat:'firewall'},
	{cmd:'/fw_disable',desc:'Disable a firewall rule',cat:'firewall'},
	{cmd:'/fw_enable',desc:'Enable a firewall rule',cat:'firewall'},
	{cmd:'/fw_list',desc:'List all firewall rules',cat:'firewall'},
	{cmd:'/fw_unblock',desc:'Remove hostname from deny firewall rule (or all if no hostname)',cat:'firewall'},
	{cmd:'/fwr_disable',desc:'Disable a redirect firewall rule',cat:'firewall'},
	{cmd:'/fwr_enable',desc:'Enable a redirect firewall rule',cat:'firewall'},
	{cmd:'/fwr_list',desc:'List all redirect firewall rules',cat:'firewall'},
	{cmd:'/get_ip',desc:'Get the WAN IP Address',cat:'network'},
	{cmd:'/get_mac',desc:'Get the organization owning the MAC address',cat:'network'},
	{cmd:'/get_ping',desc:'Ping an address or host, returns Up or Down',cat:'network'},
	{cmd:'/get_uptime',desc:'Return the uptime of this device',cat:'system'},
	{cmd:'/hst_list',desc:'Get DHCP leased hosts',cat:'network'},
	{cmd:'/ignoredmac_add',desc:'Add a MAC address to the allowlist (no notifications)',cat:'network'},
	{cmd:'/ignoredmac_list',desc:'Show the list of ignored MAC addresses',cat:'network'},
	{cmd:'/interface_down',desc:'Shut down an interface by its name',cat:'network'},
	{cmd:'/interface_restart',desc:'Restart an interface by its name',cat:'network'},
	{cmd:'/interface_up',desc:'Start up an interface by its name',cat:'network'},
	{cmd:'/interfaces_list',desc:'Get interfaces configuration',cat:'network'},
	{cmd:'/lights',desc:'Turn on/off household lights',cat:'smart_home'},
	{cmd:'/msg_tv',desc:'Send a message to a Samsung TV',cat:'smart_home'},
	{cmd:'/netstat',desc:'Print network statistics (established, closed, timed wait)',cat:'network'},
	{cmd:'/opkg_install',desc:'Install a package via OPKG',cat:'system'},
	{cmd:'/opkg_update',desc:'Update the list of available packages',cat:'system'},
	{cmd:'/ping_udp',desc:'Create a UDP packet to punch a hole through NAT firewalls',cat:'network'},
	{cmd:'/proc_list',desc:'List all running processes',cat:'system'},
	{cmd:'/proc_restart',desc:'Restart a process in init.d',cat:'system'},
	{cmd:'/proc_start',desc:'Start a process in init.d',cat:'system'},
	{cmd:'/proc_stop',desc:'Stop a process in init.d',cat:'system'},
	{cmd:'/proxy_disable',desc:'Disable HTTP and/or HTTPS proxy',cat:'proxy'},
	{cmd:'/proxy_enable',desc:'Enable HTTP and/or HTTPS proxy',cat:'proxy'},
	{cmd:'/proxy_list',desc:'List enabled proxy rules',cat:'proxy'},
	{cmd:'/reboot',desc:'Reboot the router',cat:'system'},
	{cmd:'/swports_list',desc:'List switch ports with their current states',cat:'network'},
	{cmd:'/wifi_disable',desc:'Disable a wireless device radio',cat:'wifi'},
	{cmd:'/wifi_enable',desc:'Enable a wireless device radio',cat:'wifi'},
	{cmd:'/wifi_list',desc:'List all wireless devices',cat:'wifi'},
	{cmd:'/wifi_restart',desc:'Restart a wireless device radio',cat:'wifi'},
	{cmd:'/wll_list',desc:'Get a list of Wi-Fi clients connected to this device',cat:'wifi'}
];
var catNames = {
	general:_('General'), camera:_('IP Camera'), chromego:_('ChromeGo'),
	firewall:_('Firewall'), network:_('Network'), system:_('System'),
	smart_home:_('Smart Home'), proxy:_('Proxy'), wifi:_('Wi-Fi')
};
function renderCommandTable(filter) {
	var filtered = botCommands.filter(function(c) {
		if (!filter) return true;
		var f = filter.toLowerCase();
		return c.cmd.toLowerCase().indexOf(f) !== -1 ||
			c.desc.toLowerCase().indexOf(f) !== -1 ||
			(catNames[c.cat] || c.cat).toLowerCase().indexOf(f) !== -1;
	});
	if (filtered.length === 0)
		return E('p', {}, _('No commands found matching your search.'));
	var table = E('table', {'class':'table tg-cmd-table'}, [
		E('tr', {'class':'tr table-titles'}, [
			E('th', {'class':'th', style:'width:22%'}, _('Command')),
			E('th', {'class':'th', style:'width:60%'}, _('Description')),
			E('th', {'class':'th', style:'width:18%'}, _('Category'))
		])
	]);
	filtered.forEach(function(c) {
		table.appendChild(E('tr', {'class':'tr'}, [
			E('td', {'class':'td'}, E('code', {}, c.cmd)),
			E('td', {'class':'td', style:'font-size:.9em'}, c.desc),
			E('td', {'class':'td'}, catNames[c.cat] || c.cat)
		]));
	});
	return table;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('telegramopenwrt'),
			callTGLoad().catch(function() { return { ok: false }; }),
			callTGCheckTools().catch(function() { return { ok: false }; })
		]).then(function(results) {
			return results;
		}).catch(function(e) {
			console.error('telegramopenwrt: load failed:', e);
			return [null, {ok:false}, {ok:false}];
		});
	},

	render: function(data) {
		var loadRes = data[1] || {};
		var tools = data[2] || {};
		var service = loadRes.service || {};
		var isRunning = !!service.running;
		var isAutostart = !!service.enabled;

		var m, s, o;
		m = new form.Map('telegramopenwrt', _('Telegram Scripts for OpenWrt'),
			_('Telegram bot integration for OpenWrt. Manage bot settings, control the service, and monitor status.'));

		m.onAfterApply = function() {
			return callTGService('restart').then(function() {
				return waitForState(true, 1500, 15000);
			}).then(function(running) {
				updateStatusCard();
				if (running) {
					ui.addNotification(null, E('p', _('Service restarted with new settings.')));
				} else {
					ui.addNotification(null, E('div', {'class':'alert-message warning'},
						E('p', _('Service restart requested, but it did not start. Check the logs.'))));
				}
			}).catch(function() { updateStatusCard(); });
		};

		s = m.section(form.NamedSection, 'global', 'telegramopenwrt', _('Service Status'));

		if (tools.ok && (!tools.curl || !tools.ca_bundle)) {
			o = s.option(form.DummyValue, '_deps_warning', _('Optional Dependencies'));
			o.rawhtml = true;
			o.cfgvalue = function() {
				var html = '<div class="alert-message warning" style="margin-bottom:10px;">';
				html += '<strong>⚠ ' + _('Missing recommended packages:') + '</strong><ul style="margin:5px 0 0 0;padding-left:20px;">';
				if (!tools.curl) html += '<li><code>curl</code> — ' + _('Required for bot connection test. Install:') + ' <code>opkg install curl</code></li>';
				if (!tools.ca_bundle) html += '<li><code>ca-bundle</code> — ' + _('Required for HTTPS to Telegram API. Install:') + ' <code>opkg install ca-bundle</code></li>';
				html += '</ul></div>';
				return html;
			};
		}

		var statusColor = isRunning ? '#28a745' : '#dc3545';
		var statusBg = isRunning ? '#e8f5e9' : '#ffebee';
		var statusIcon = isRunning ? '▶' : '⏸';
		var statusText = isRunning ? _('Running') : _('Stopped');

		o = s.option(form.DummyValue, '_status_card', _('Service Status'));
		o.renderWidget = function() {
			var card = E('div', {
				id: 'tg-card',
				style: 'background:' + statusBg + ';border-left:4px solid ' + statusColor + ';'
			}, [
				E('div', {id:'tg-state', style:'font-size:1.2em;font-weight:bold;color:' + statusColor + ';'},
					statusIcon + ' ' + statusText)
			]);
			return E('div', {'class':'cbi-value-field'}, card);
		};

		o = s.option(form.Button, '_btn_start');
		o.title = _('Start the service');
		o.inputtitle = _('Start');
		o.inputstyle = 'action';
		o.onclick = function() {
			return callTGService('start').then(function() {
				return waitForState(true, 500, 12000);
			}).then(function() { updateStatusCard(); });
		};
		o = s.option(form.Button, '_btn_restart');
		o.title = _('Restart the service');
		o.inputtitle = _('Restart');
		o.inputstyle = 'action';
		o.onclick = function() {
			return callTGService('restart').then(function() {
				return waitForState(true, 1500, 15000);
			}).then(function() { updateStatusCard(); });
		};
		o = s.option(form.Button, '_btn_stop');
		o.title = _('Stop the service');
		o.inputtitle = _('Stop');
		o.inputstyle = 'negative';
		o.onclick = function() {
			return callTGService('stop').then(function() {
				return waitForState(false, 0, 10000);
			}).then(function() { updateStatusCard(); });
		};
		o = s.option(form.Button, '_btn_autostart_enable');
		o.title = _('Autostart');
		o.inputtitle = _('Disabled');
		o.inputstyle = 'negative';
		o.onclick = function() {
			return callTGService('enable').then(function() {
				ui.addNotification(null, E('p', _('Autostart enabled.')));
				updateStatusCard();
			});
		};
		o = s.option(form.Button, '_btn_autostart_disable');
		o.title = _('Autostart');
		o.inputtitle = _('Enabled');
		o.inputstyle = 'positive';
		o.onclick = function() {
			return callTGService('disable').then(function() {
				ui.addNotification(null, E('p', _('Autostart disabled.')));
				updateStatusCard();
			});
		};

		s = m.section(form.NamedSection, 'global', 'telegramopenwrt', _('Bot Connection & Logs'));

		o = s.option(form.Button, '_btn_test_bot');
		o.title = _('Bot Connection Test');
		o.inputtitle = _('Test Bot Connection');
		o.description = _('Sends a getMe request to the Telegram Bot API to verify the token and connectivity.');
		o.inputstyle = 'action';
		o.onclick = function(ev) {
			var btn = ev.currentTarget;
			btn.disabled = true;
			btn.textContent = _('Testing…');
			return callTGTestBot().then(function(res) {
				btn.disabled = false;
				btn.textContent = _('Test Bot Connection');
				if (res && res.bot_ok) {
					ui.addNotification(null, E('div', {'class':'alert-message success'},
						E('p', {}, [
							E('strong', {}, _('Bot connected successfully!')), E('br'),
							_('Username:') + ' @' + esc(res.username || 'unknown'),
							res.bot_id ? E('br') : null,
							res.bot_id ? _('Bot ID:') + ' ' + res.bot_id : null
						])));
				} else {
					ui.addNotification(null, E('div', {'class':'alert-message error'},
						E('p', {}, [
							E('strong', {}, _('Bot test failed:')), E('br'),
							esc(res && res.error ? res.error : _('Unknown error'))
						])));
				}
			}).catch(function(err) {
				btn.disabled = false;
				btn.textContent = _('Test Bot Connection');
				ui.addNotification(null, E('p', _('Error: ') + (err.message || err)));
			});
		};

		o = s.option(form.Button, '_btn_live_tail');
		o.title = _('Service Logs');
		o.inputtitle = _('View Log (Live Tail)');
		o.description = _('Opens the system log with real-time updates (every 2 seconds).');
		o.inputstyle = 'action';
		o.onclick = function() { return openLogTail(); };

		s = m.section(form.NamedSection, 'global', 'telegramopenwrt', _('Global Parameters'));

		o = s.option(form.Value, 'key', _('Bot Token'));
		o.password = true;
		o.description = _('Create a bot via') + ' <a href="https://t.me/BotFather" target="_blank">@BotFather</a> ' +
			_('and obtain a Bot token. Example:') + ' <code>123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11</code>';
		o.validate = function(section_id, value) {
			if (value === '') return true;
			if (!/^\d{6,12}:[A-Za-z0-9_-]{20,60}$/.test(value))
				return _('Invalid token format. Expected: 123456789:ABCdefGHI…');
			return true;
		};
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('Bot URL API'));
		o.placeholder = 'https://api.telegram.org';
		o.validate = function(section_id, value) {
			if (value === '') return true;
			if (!/^https?:\/\/.+/.test(value))
				return _('Must be http:// or https:// URL');
			return true;
		};

		o = s.option(form.Value, 'my_chat_id', _('Chat ID'));
		o.description = _('Get your Chat ID from') +
			' <a href="https://core.telegram.org/api/bots/ids#chat-ids" target="_blank">' +
			_('Telegram documentation') + '</a>.';
		o.validate = function(section_id, value) {
			if (value === '') return true;
			if (!/^-?\d+$/.test(value))
				return _('Must be a number (negative for groups/channels)');
			return true;
		};
		o.rmempty = false;

		o = s.option(form.Value, 'timeout', _('Connection Timeout (seconds)'));
		o.validate = function(section_id, value) {
			if (value === '') return true;
			if (!/^\d+$/.test(value) || parseInt(value) < 1)
				return _('Must be a positive whole number');
			return true;
		};

		o = s.option(form.Value, 'ignored_macaddrs_file', _('MAC Addresses Ignore List File'));
		o.description = _('Path to file with MAC addresses that will not trigger notifications.');

		o = s.option(form.Button, '_btn_edit_macignore');
		o.title = _('MAC Addresses Ignore List File');
		o.inputtitle = _('Edit Ignore List');
		o.description = _('Edit the file with MAC addresses that will not trigger notifications. One MAC address per line.');
		o.inputstyle = 'action';
		o.onclick = function() {
			return openFileEditor(
				'macignore',
				_('Edit MAC Ignore List'),
				_('One MAC address per line. Devices with these MAC addresses will not trigger DHCP/port notifications from the bot.'),
				'# MAC addresses to ignore (one per line)\n# Example: AA:BB:CC:DD:EE:FF\n'
			);
		};

		// ========== IP CAMERA ==========
		s = m.section(form.NamedSection, 'ipcam', 'telegramopenwrt', _('IP Camera Configuration'));
		s.description = _('Settings for IP camera integration. Used by commands /cam_movie, /cam_shot, /cam_vdo, /cam_mv. Camera must support /snapshot.cgi and /videostream.asf endpoints (typical for D-Link, Foscam, and similar IP cameras).');

		o = s.option(form.Value, 'ipaddr', _('Camera IP or Hostname'));
		o.datatype = 'host';
		o.description = _('IP address or hostname of your IP camera. Example: 192.168.1.100 or cam.local');

		o = s.option(form.Value, 'user', _('Camera Username'));
		o.description = _('Username for camera authentication. Used in URL parameters for snapshot and video stream requests.');

		o = s.option(form.Value, 'passwd', _('Camera Password'));
		o.password = true;
		o.description = _('Password for camera authentication. Used in URL parameters for snapshot and video stream requests.');

		o = s.option(form.Value, 'header_auth', _('HTTP Authentication Header Value'));
		o.description = _('HTTP Basic Auth header value (base64-encoded "username:password"). Used for cameras that require header-based authentication instead of URL parameters.');

		// ========== SMTP ==========
		s = m.section(form.NamedSection, 'smtp', 'telegramopenwrt', _('SMTP Email Notifications'));
		s.description = _('Email notification settings. When an unauthorized user (not matching your Chat ID) tries to interact with the bot, an email alert is sent via ssmtp. Requires ssmtp package to be installed and configured on the router.');

		o = s.option(form.Value, 'from', _('E-Mail Sender Address'));
		o.datatype = 'email';
		o.description = _('Email address that will appear as the sender. Example: router@example.com');

		o = s.option(form.Value, 'to', _('E-Mail Recipient Address'));
		o.datatype = 'email';
		o.description = _('Email address where unauthorized access alerts will be sent. This should be your email address.');

		// ========== TELEVISION ==========
		s = m.section(form.NamedSection, 'television', 'telegramopenwrt', _('Television Settings'));
		s.description = _('Settings for sending messages to Samsung Smart TV via SOAP API (MessageBoxService on port 52235). Only works with Samsung Smart TVs that support this service. Used by the /msg_tv command.');

		o = s.option(form.Value, 'ipaddr', _('TV Device IP Address'));
		o.datatype = 'ipaddr';
		o.description = _('IP address of your Samsung Smart TV. The TV must be on the same network and have MessageBoxService enabled.');

		o = s.option(form.Value, 'sender_name', _('Sender Name'));
		o.description = _('Name that will appear as the sender of the message on the TV screen. Example: "Router" or "Admin"');

		o = s.option(form.Value, 'sender_number', _('Sender Number'));
		o.description = _('Phone number or identifier for the sender. Example: "+1234567890" or "ROUTER"');

		o = s.option(form.Value, 'receiver_name', _('Receiver Name'));
		o.description = _('Name that will appear as the recipient of the message on the TV screen. Example: "User" or "Family"');

		o = s.option(form.Value, 'receiver_number', _('Receiver Number'));
		o.description = _('Phone number or identifier for the recipient. Example: "+0987654321" or "TV"');

		// ========== PROXY ==========
		s = m.section(form.NamedSection, 'proxy', 'telegramopenwrt', _('Proxy Server'));

		o = s.option(form.DummyValue, '_proxy_warning', _(''));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<div class="alert-message warning">' +
				'<strong>⚠ ' + _('Warning:') + '</strong> ' +
				_('The proxy server parameters (IP address, network, interface, firewall mark) are hardcoded in the script') +
				' <code>/sbin/proxy</code>. ' +
				_('To change them, edit the file directly via SSH. The switches below only enable/disable the iptables rules.') +
				'<br/><br/>' +
				'</ul></div>';
		};

		o = s.option(form.ListValue, 'http', _('Enable HTTP Proxy'));
		o.value('true', _('True'));
		o.value('false', _('False'));
		o.default = 'false';
		o = s.option(form.ListValue, 'https', _('Enable HTTPS Proxy'));
		o.value('true', _('True'));
		o.value('false', _('False'));
		o.default = 'false';

		// ========== BOT COMMANDS ==========
		s = m.section(form.NamedSection, 'global', 'telegramopenwrt', _('Bot Commands Reference'));
		o = s.option(form.DummyValue, '_commands', _('Available Commands'));
		o.description = _('Send these commands to your bot in Telegram. Use the search box to filter.');
		o.cfgvalue = function() {
			var searchInput = E('input', {
				type: 'text', 'class': 'cbi-input-text',
				placeholder: _('Search commands…'),
				style: 'width:100%;margin-bottom:10px;'
			});
			var countDiv = E('div', {style:'font-size:.85em;color:#666;margin-bottom:8px;'},
				botCommands.length + ' ' + _('commands total'));
			var tableDiv = E('div', {style:'max-height:400px;overflow-y:auto;'});
			searchInput.addEventListener('input', function() {
				tableDiv.innerHTML = '';
				tableDiv.appendChild(renderCommandTable(this.value));
			});
			tableDiv.appendChild(renderCommandTable(''));
			return E('div', {}, [searchInput, countDiv, tableDiv]);
		};

		injectStyle();
		var self = this;
		return m.render().then(function(el) {
			var btnStart = el.querySelector('#cbid\\.telegramopenwrt\\.global\\._btn_start');
			var btnStop = el.querySelector('#cbid\\.telegramopenwrt\\.global\\._btn_stop');
			var btnRestart = el.querySelector('#cbid\\.telegramopenwrt\\.global\\._btn_restart');
			var btnAutoEn = el.querySelector('#cbid\\.telegramopenwrt\\.global\\._btn_autostart_enable');
			var btnAutoDis = el.querySelector('#cbid\\.telegramopenwrt\\.global\\._btn_autostart_disable');
			if (btnStart) { var r = btnStart.closest('.cbi-value'); if (r) r.style.display = isRunning ? 'none' : ''; }
			if (btnStop) { var r2 = btnStop.closest('.cbi-value'); if (r2) r2.style.display = isRunning ? '' : 'none'; }
			if (btnRestart) { var r3 = btnRestart.closest('.cbi-value'); if (r3) r3.style.display = isRunning ? '' : 'none'; }
			if (btnAutoEn) { var r4 = btnAutoEn.closest('.cbi-value'); if (r4) r4.style.display = isAutostart ? 'none' : ''; }
			if (btnAutoDis) { var r5 = btnAutoDis.closest('.cbi-value'); if (r5) r5.style.display = isAutostart ? '' : 'none'; }

			updateStatusCard();
			poll.add(function() { return updateStatusCard(); }, 5);

			self._visibilityHandler = function() {
				handleLogTailVisibility();
				if (!document.hidden) updateStatusCard();
			};
			document.addEventListener('visibilitychange', self._visibilityHandler);
			return el;
		});
	},

	remove: function() {
		logTailCleanup();
		if (this._visibilityHandler) {
			document.removeEventListener('visibilitychange', this._visibilityHandler);
			this._visibilityHandler = null;
		}
	}
});
JSEOF

# ---------------- ACL ----------------
mkdir -p "$telegramopenwrtLuciSource"/usr/share/rpcd/acl.d/
cat << 'EOF' > "$telegramopenwrtLuciSource"/usr/share/rpcd/acl.d/luci-app-telegramopenwrt.json
{
	"luci-app-telegramopenwrt": {
		"description": "Grant access to Telegram Scripts for OpenWrt",
		"read": {
			"uci": ["telegramopenwrt"],
			"ubus": {
				"telegramopenwrt": [
					"status", "load", "test_bot", "log_tail", "check_tools", "file_read"
				]
			}
		},
		"write": {
			"uci": ["telegramopenwrt"],
			"ubus": {
				"telegramopenwrt": [
					"service", "file_write"
				]
			}
		}
	}
}
EOF

# ---------------- Menu ----------------
mkdir -p "$telegramopenwrtLuciSource"/usr/share/luci/menu.d/
cat << 'EOF' > "$telegramopenwrtLuciSource"/usr/share/luci/menu.d/luci-app-telegramopenwrt.json
{
	"admin/services/telegramopenwrt": {
		"title": "Telegram Scripts",
		"action": { "type": "view", "path": "telegramopenwrt" },
		"depends": {
			"acl": ["luci-app-telegramopenwrt"],
			"uci": { "telegramopenwrt": true }
		}
	}
}
EOF

# ---------------- CONTROL ----------------
mkdir -p "$telegramopenwrtLuciSource"/CONTROL/
cat << EOF > "$telegramopenwrtLuciSource"/CONTROL/control
Package: luci-app-telegramopenwrt
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: telegram-openwrt, luci-base, rpcd
Source: feeds/packages/luci-app-telegramopenwrt
SourceName: luci-app-telegramopenwrt
License: GPL-2.0
Section: luci
SourceDateEpoch: ${SOURCE_DATE_EPOCH}
Architecture: all
URL: https://github.com/alexwbaule/telegramopenwrt
Maintainer: Alex W. Baule
Installed-Size:
Description: LuCI web interface for Telegram Scripts for OpenWrt. Full service management, bot connection testing, live log tail, and command reference.
EOF

cat << 'EOF' > "$telegramopenwrtLuciSource"/CONTROL/postinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

cat << 'EOF' > "$telegramopenwrtLuciSource"/CONTROL/prerm
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF
chmod +x "$telegramopenwrtLuciSource/CONTROL/postinst"
chmod +x "$telegramopenwrtLuciSource/CONTROL/prerm"
}

# ============================================================================
# Пакет русского перевода
# ============================================================================
compileTelegramopenwrtI18n()
{
echo "Происходит компиляция утилиты po2lmo из исходников, подождите…"
LUCI_BASE="https://raw.githubusercontent.com/openwrt/luci/master/modules/luci-base/src"
mkdir -p po2lmo-src/lib po2lmo-src/contrib
curl -Ls -o po2lmo-src/po2lmo.c              "$LUCI_BASE/po2lmo.c"
curl -Ls -o po2lmo-src/lib/lmo.c             "$LUCI_BASE/lib/lmo.c"
curl -Ls -o po2lmo-src/lib/lmo.h             "$LUCI_BASE/lib/lmo.h"
curl -Ls -o po2lmo-src/lib/plural_formula.y  "$LUCI_BASE/lib/plural_formula.y"
curl -Ls -o po2lmo-src/contrib/lemon.c       "$LUCI_BASE/contrib/lemon.c"
curl -Ls -o po2lmo-src/contrib/lempar.c      "$LUCI_BASE/contrib/lempar.c"
cd po2lmo-src
gcc -std=gnu17 -o contrib/lemon contrib/lemon.c >/dev/null 2>&1
./contrib/lemon -q lib/plural_formula.y >/dev/null 2>&1
gcc -c -o po2lmo.o po2lmo.c
gcc -c -o lib/lmo.o lib/lmo.c -I. -DNDEBUG
gcc -c -o lib/plural_formula.o lib/plural_formula.c -DNDEBUG
gcc -o po2lmo po2lmo.o lib/lmo.o lib/plural_formula.o
cp po2lmo ../po2lmo
cd ..
echo "Утилита po2lmo скомпилирована"

mkdir -p po/ru
cat << 'POEOF' > po/ru/telegramopenwrt.po
msgid ""
msgstr ""
"Project-Id-Version: luci-app-telegramopenwrt\n"
"PO-Revision-Date: 2026-10-30 12:00+0300\n"
"Language-Team: Russian\n"
"Language: ru\n"
"MIME-Version: 1.0\n"
"Content-Type: text/plain; charset=UTF-8\n"
"Content-Transfer-Encoding: 8bit\n"
"Plural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n"

# ============================================================
# ЗАГОЛОВКИ И ОБЩИЕ
# ============================================================
msgid "Telegram Scripts for OpenWrt"
msgstr "Telegram Scripts для OpenWrt"

msgid "Telegram bot integration for OpenWrt. Manage bot settings, control the service, and monitor status."
msgstr "Интеграция Telegram-бота для OpenWrt. Управление настройками бота, контроль службы и мониторинг статуса."

# ============================================================
# СТАТУС СЛУЖБЫ
# ============================================================
msgid "Service Status"
msgstr "Состояние службы"

msgid "Running"
msgstr "Запущен"

msgid "Stopped"
msgstr "Остановлен"

msgid "Start the service"
msgstr "Запуск службы"

msgid "Start"
msgstr "Запустить"

msgid "Restart the service"
msgstr "Перезапуск службы"

msgid "Restart"
msgstr "Перезапустить"

msgid "Stop the service"
msgstr "Остановка службы"

msgid "Stop"
msgstr "Остановить"

msgid "Autostart"
msgstr "Автозапуск"

msgid "Autostart enabled."
msgstr "Автозапуск включён."

msgid "Autostart disabled."
msgstr "Автозапуск выключен."

msgid "Service restarted with new settings."
msgstr "Служба перезапущена с новыми настройками."

msgid "Service restart requested, but it did not start. Check the logs."
msgstr "Запрошен перезапуск службы, но она не запустилась. Проверьте логи."

# ============================================================
# ПРОВЕРКА БОТА И ЛОГИ
# ============================================================
msgid "Bot Connection & Logs"
msgstr "Проверка бота и логи"

msgid "Bot Connection Test"
msgstr "Проверка соединения с ботом"

msgid "Test Bot Connection"
msgstr "Проверить соединение с ботом"

msgid "Sends a getMe request to the Telegram Bot API to verify the token and connectivity."
msgstr "Отправляет запрос getMe к Telegram Bot API для проверки токена и соединения."

msgid "Testing…"
msgstr "Проверка…"

msgid "Bot connected successfully!"
msgstr "Бот успешно подключен!"

msgid "Username:"
msgstr "Имя пользователя:"

msgid "Bot ID:"
msgstr "ID бота:"

msgid "Bot test failed:"
msgstr "Ошибка проверки бота:"

msgid "Unknown error"
msgstr "Неизвестная ошибка"

msgid "Error: "
msgstr "Ошибка: "

msgid "Service Logs"
msgstr "Логи службы"

msgid "View Log (Live Tail)"
msgstr "Просмотр лога (Live Tail)"

msgid "Opens the system log with real-time updates (every 2 seconds)."
msgstr "Открывает системный лог с обновлениями в реальном времени (каждые 2 секунды)."

msgid "Telegram Bot Log — Live Tail"
msgstr "Лог Telegram-бота — Live Tail"

msgid "Start Live Tail"
msgstr "Запустить Live Tail"

msgid "Stop Live Tail"
msgstr "Остановить Live Tail"

msgid "Live tail active - updating every 2 seconds"
msgstr "Live tail активен — обновление каждые 2 секунды"

msgid "Live tail paused"
msgstr "Live tail на паузе"

msgid "Live tail stopped"
msgstr "Live tail остановлен"

msgid "Source: "
msgstr "Источник: "

msgid "Failed to read system log: "
msgstr "Не удалось прочитать системный лог: "

msgid "No telegram_bot entries found in system log. Make sure the service has been started at least once."
msgstr "В системном логе не найдено записей telegram_bot. Убедитесь, что служба была запущена хотя бы один раз."

msgid "Loading…"
msgstr "Загрузка…"

msgid "lines"
msgstr "строк"

msgid "Copy"
msgstr "Копировать"

msgid "Close"
msgstr "Закрыть"

msgid "Log copied to clipboard."
msgstr "Лог скопирован в буфер обмена."

msgid "Copy failed. Please select text manually."
msgstr "Не удалось скопировать. Выделите текст вручную."

# ============================================================
# ОПЦИОНАЛЬНЫЕ ЗАВИСИМОСТИ
# ============================================================
msgid "Optional Dependencies"
msgstr "Опциональные зависимости"

msgid "Missing recommended packages:"
msgstr "Отсутствуют рекомендуемые пакеты:"

msgid "Required for bot connection test. Install:"
msgstr "Требуется для проверки соединения с ботом. Установка:"

msgid "Required for HTTPS to Telegram API. Install:"
msgstr "Требуется для HTTPS к Telegram API. Установка:"

# ============================================================
# ГЛОБАЛЬНЫЕ НАСТРОЙКИ
# ============================================================
msgid "Global Parameters"
msgstr "Глобальные параметры"

msgid "Bot Token"
msgstr "Токен бота"

msgid "Create a bot via"
msgstr "Создайте бота через"

msgid "and obtain a Bot token. Example:"
msgstr "и получите токен бота. Пример:"

msgid "Invalid token format. Expected: 123456789:ABCdefGHI…"
msgstr "Неверный формат токена. Ожидается: 123456789:ABCdefGHI…"

msgid "Bot URL API"
msgstr "URL API бота"

msgid "Must be http:// or https:// URL"
msgstr "Должен быть URL вида http:// или https://"

msgid "Chat ID"
msgstr "ID чата"

msgid "Get your Chat ID from"
msgstr "Получите свой Chat ID из"

msgid "Telegram documentation"
msgstr "документации Telegram"

msgid "Must be a number (negative for groups/channels)"
msgstr "Должно быть числом (отрицательное для групп/каналов)"

msgid "Connection Timeout (seconds)"
msgstr "Таймаут соединения (секунды)"

msgid "Must be a positive whole number"
msgstr "Должно быть положительное целое число"

msgid "MAC Addresses Ignore List File"
msgstr "Файл списка игнорируемых MAC-адресов"

msgid "Path to file with MAC addresses that will not trigger notifications."
msgstr "Путь к файлу с MAC-адресами, которые не будут вызывать уведомления."

msgid "Edit Ignore List"
msgstr "Редактировать список игнорирования"

msgid "Edit the file with MAC addresses that will not trigger notifications. One MAC address per line."
msgstr "Редактирование файла с MAC-адресами, которые не будут вызывать уведомления. Один MAC-адрес на строку."

msgid "Edit MAC Ignore List"
msgstr "Редактирование списка игнорируемых MAC-адресов"

msgid "One MAC address per line. Devices with these MAC addresses will not trigger DHCP/port notifications from the bot."
msgstr "Один MAC-адрес на строку. Устройства с этими MAC-адресами не будут вызывать уведомления бота о DHCP/портах."

msgid "File does not exist yet. It will be created when you save."
msgstr "Файл ещё не существует. Он будет создан при сохранении."

msgid "Failed to read file: "
msgstr "Не удалось прочитать файл: "

msgid "Failed to save: "
msgstr "Не удалось сохранить: "

msgid "File saved successfully!"
msgstr "Файл успешно сохранён!"

msgid "Save"
msgstr "Сохранить"

msgid "Cancel"
msgstr "Отмена"

# ============================================================
# IP-КАМЕРА (с описаниями)
# ============================================================
msgid "IP Camera Configuration"
msgstr "Настройка IP-камеры"

msgid "Settings for IP camera integration. Used by commands /cam_movie, /cam_shot, /cam_vdo, /cam_mv. Camera must support /snapshot.cgi and /videostream.asf endpoints (typical for D-Link, Foscam, and similar IP cameras)."
msgstr "Настройки интеграции с IP-камерой. Используется командами /cam_movie, /cam_shot, /cam_vdo, /cam_mv. Камера должна поддерживать эндпоинты /snapshot.cgi и /videostream.asf (типично для D-Link, Foscam и подобных IP-камер)."

msgid "Camera IP or Hostname"
msgstr "IP или имя хоста камеры"

msgid "IP address or hostname of your IP camera. Example: 192.168.1.100 or cam.local"
msgstr "IP-адрес или имя хоста вашей IP-камеры. Пример: 192.168.1.100 или cam.local"

msgid "Camera Username"
msgstr "Имя пользователя камеры"

msgid "Username for camera authentication. Used in URL parameters for snapshot and video stream requests."
msgstr "Имя пользователя для аутентификации камеры. Используется в параметрах URL при запросах снимков и видеопотоков."

msgid "Camera Password"
msgstr "Пароль камеры"

msgid "Password for camera authentication. Used in URL parameters for snapshot and video stream requests."
msgstr "Пароль для аутентификации камеры. Используется в параметрах URL при запросах снимков и видеопотоков."

msgid "HTTP Authentication Header Value"
msgstr "Значение заголовка HTTP-аутентификации"

msgid "HTTP Basic Auth header value (base64-encoded \"username:password\"). Used for cameras that require header-based authentication instead of URL parameters."
msgstr "Значение заголовка HTTP Basic Auth (base64-кодированное «username:password»). Используется для камер, требующих аутентификации через заголовок, а не через параметры URL."

# ============================================================
# SMTP (с описаниями)
# ============================================================
msgid "SMTP Email Notifications"
msgstr "SMTP Email-уведомления"

msgid "Email notification settings. When an unauthorized user (not matching your Chat ID) tries to interact with the bot, an email alert is sent via ssmtp. Requires ssmtp package to be installed and configured on the router."
msgstr "Настройки email-уведомлений. Когда неавторизованный пользователь (не совпадающий с вашим Chat ID) пытается взаимодействовать с ботом, через ssmtp отправляется email-оповещение. Требуется установленный и настроенный пакет ssmtp на роутере."

msgid "E-Mail Sender Address"
msgstr "Адрес отправителя"

msgid "Email address that will appear as the sender. Example: router@example.com"
msgstr "Email-адрес, который будет отображаться как отправитель. Пример: router@example.com"

msgid "E-Mail Recipient Address"
msgstr "Адрес получателя"

msgid "Email address where unauthorized access alerts will be sent. This should be your email address."
msgstr "Email-адрес, на который будут отправляться оповещения о несанкционированном доступе. Это должен быть ваш email-адрес."

# ============================================================
# ТЕЛЕВИЗОР (с описаниями)
# ============================================================
msgid "Television Settings"
msgstr "Настройки телевизора"

msgid "Settings for sending messages to Samsung Smart TV via SOAP API (MessageBoxService on port 52235). Only works with Samsung Smart TVs that support this service. Used by the /msg_tv command."
msgstr "Настройки для отправки сообщений на Samsung Smart TV через SOAP API (MessageBoxService на порту 52235). Работает только с Samsung Smart TV, поддерживающими эту службу. Используется командой /msg_tv."

msgid "TV Device IP Address"
msgstr "IP-адрес телевизора"

msgid "IP address of your Samsung Smart TV. The TV must be on the same network and have MessageBoxService enabled."
msgstr "IP-адрес вашего Samsung Smart TV. Телевизор должен находиться в той же сети и иметь включённую службу MessageBoxService."

msgid "Sender Name"
msgstr "Имя отправителя"

msgid "Name that will appear as the sender of the message on the TV screen. Example: \"Router\" or \"Admin\""
msgstr "Имя, которое будет отображаться как отправитель сообщения на экране телевизора. Пример: «Router» или «Admin»"

msgid "Sender Number"
msgstr "Номер отправителя"

msgid "Phone number or identifier for the sender. Example: \"+1234567890\" or \"ROUTER\""
msgstr "Номер телефона или идентификатор отправителя. Пример: «+1234567890» или «ROUTER»"

msgid "Receiver Name"
msgstr "Имя получателя"

msgid "Name that will appear as the recipient of the message on the TV screen. Example: \"User\" or \"Family\""
msgstr "Имя, которое будет отображаться как получатель сообщения на экране телевизора. Пример: «User» или «Family»"

msgid "Receiver Number"
msgstr "Номер получателя"

msgid "Phone number or identifier for the recipient. Example: \"+0987654321\" or \"TV\""
msgstr "Номер телефона или идентификатор получателя. Пример: «+0987654321» или «TV»"

# ============================================================
# ПРОКСИ-СЕРВЕР
# ============================================================
msgid "Proxy Server"
msgstr "Прокси-сервер"

msgid "Warning:"
msgstr "Предупреждение:"

msgid "The proxy server parameters (IP address, network, interface, firewall mark) are hardcoded in the script"
msgstr "Параметры прокси-сервера (IP-адрес, сеть, интерфейс, метка файрвола) захардкожены в скрипте"

msgid "To change them, edit the file directly via SSH. The switches below only enable/disable the iptables rules."
msgstr "Для их изменения отредактируйте файл напрямую через SSH. Переключатели ниже лишь включают/выключают правила iptables."

msgid "Current hardcoded values:"
msgstr "Текущие захардкоженные значения:"

msgid "Enable HTTP Proxy"
msgstr "Включить HTTP-прокси"

msgid "Enable HTTPS Proxy"
msgstr "Включить HTTPS-прокси"

msgid "True"
msgstr "Включено"

msgid "False"
msgstr "Выключено"

# ============================================================
# СПРАВОЧНИК КОМАНД БОТА
# ============================================================
msgid "Bot Commands Reference"
msgstr "Справочник команд бота"

msgid "Available Commands"
msgstr "Доступные команды"

msgid "Send these commands to your bot in Telegram. Use the search box to filter."
msgstr "Отправляйте эти команды вашему боту в Telegram. Используйте поле поиска для фильтрации."

msgid "Search commands…"
msgstr "Поиск команд…"

msgid "commands total"
msgstr "команд всего"

msgid "No commands found matching your search."
msgstr "Команды по вашему запросу не найдены."

msgid "Command"
msgstr "Команда"

msgid "Description"
msgstr "Описание"

msgid "Category"
msgstr "Категория"

# Категории
msgid "General"
msgstr "Общие"

msgid "IP Camera"
msgstr "IP-камера"

msgid "ChromeGo"
msgstr "ChromeGo"

msgid "Firewall"
msgstr "Файрвол"

msgid "Network"
msgstr "Сеть"

msgid "System"
msgstr "Система"

msgid "Smart Home"
msgstr "Умный дом"

msgid "Proxy"
msgstr "Прокси"

msgid "Wi-Fi"
msgstr "Wi-Fi"

# ============================================================
# ОПИСАНИЯ КОМАНД БОТА
# ============================================================
msgid "Display help menu"
msgstr "Показать меню помощи"

msgid "Record 25 seconds of a camIP and send it"
msgstr "Записать 25 секунд с IP-камеры и отправить"

msgid "Move the camera around"
msgstr "Перемещать камеру"

msgid "Get a picture from the camera"
msgstr "Получить снимок с камеры"

msgid "Get a 25 seconds recording from a camIP"
msgstr "Получить 25-секундную запись с IP-камеры"

msgid "Include a word to be blocked in ChromeGo permissions"
msgstr "Добавить слово для блокировки в разрешениях ChromeGo"

msgid "Remove a word from ChromeGo permissions"
msgstr "Удалить слово из разрешений ChromeGo"

msgid "List all ChromeGo permissions"
msgstr "Показать все разрешения ChromeGo"

msgid "Block a hostname using a deny rule in the firewall (optional: hours 23:00–08:00)"
msgstr "Заблокировать имя хоста правилом запрета в файрволе (опционально: часы 23:00–08:00)"

msgid "Remove a hostname from a deny firewall rule"
msgstr "Удалить имя хоста из правила запрета файрвола"

msgid "Disable a firewall rule"
msgstr "Отключить правило файрвола"

msgid "Enable a firewall rule"
msgstr "Включить правило файрвола"

msgid "List all firewall rules"
msgstr "Показать все правила файрвола"

msgid "Remove hostname from deny firewall rule (or all if no hostname)"
msgstr "Удалить имя хоста из правила запрета файрвола (или все, если имя не указано)"

msgid "Disable a redirect firewall rule"
msgstr "Отключить правило перенаправления файрвола"

msgid "Enable a redirect firewall rule"
msgstr "Включить правило перенаправления файрвола"

msgid "List all redirect firewall rules"
msgstr "Показать все правила перенаправления файрвола"

msgid "Get the WAN IP Address"
msgstr "Получить внешний WAN IP-адрес"

msgid "Get the organization owning the MAC address"
msgstr "Получить организацию-владельца MAC-адреса"

msgid "Ping an address or host, returns Up or Down"
msgstr "Пинг адреса или хоста, возвращает «Доступен» или «Недоступен»"

msgid "Return the uptime of this device"
msgstr "Вернуть время работы этого устройства"

msgid "Get DHCP leased hosts"
msgstr "Получить список DHCP-аренд"

msgid "Add a MAC address to the allowlist (no notifications)"
msgstr "Добавить MAC-адрес в список разрешённых (без уведомлений)"

msgid "Show the list of ignored MAC addresses"
msgstr "Показать список игнорируемых MAC-адресов"

msgid "Shut down an interface by its name"
msgstr "Выключить интерфейс по его имени"

msgid "Restart an interface by its name"
msgstr "Перезапустить интерфейс по его имени"

msgid "Start up an interface by its name"
msgstr "Включить интерфейс по его имени"

msgid "Get interfaces configuration"
msgstr "Получить конфигурацию интерфейсов"

msgid "Turn on/off household lights"
msgstr "Включить/выключить домашнее освещение"

msgid "Send a message to a Samsung TV"
msgstr "Отправить сообщение на телевизор Samsung"

msgid "Print network statistics (established, closed, timed wait)"
msgstr "Вывести сетевую статистику (установленные, закрытые, ожидающие соединения)"

msgid "Install a package via OPKG"
msgstr "Установить пакет через OPKG"

msgid "Update the list of available packages"
msgstr "Обновить список доступных пакетов"

msgid "Create a UDP packet to punch a hole through NAT firewalls"
msgstr "Создать UDP-пакет для пробива отверстия в NAT-файрволах"

msgid "List all running processes"
msgstr "Показать все запущенные процессы"

msgid "Restart a process in init.d"
msgstr "Перезапустить процесс из init.d"

msgid "Start a process in init.d"
msgstr "Запустить процесс из init.d"

msgid "Stop a process in init.d"
msgstr "Остановить процесс из init.d"

msgid "Disable HTTP and/or HTTPS proxy"
msgstr "Отключить HTTP и/или HTTPS прокси"

msgid "Enable HTTP and/or HTTPS proxy"
msgstr "Включить HTTP и/или HTTPS прокси"

msgid "List enabled proxy rules"
msgstr "Показать включённые правила прокси"

msgid "Reboot the router"
msgstr "Перезагрузить роутер"

msgid "List switch ports with their current states"
msgstr "Показать порты коммутатора с их текущими состояниями"

msgid "Disable a wireless device radio"
msgstr "Отключить радио беспроводного устройства"

msgid "Enable a wireless device radio"
msgstr "Включить радио беспроводного устройства"

msgid "List all wireless devices"
msgstr "Показать все беспроводные устройства"

msgid "Restart a wireless device radio"
msgstr "Перезапустить радио беспроводного устройства"

msgid "Get a list of Wi-Fi clients connected to this device"
msgstr "Получить список Wi-Fi клиентов, подключённых к этому устройству"
POEOF

mkdir -p "$telegramopenwrtI18nSource"/usr/lib/lua/luci/i18n
./po2lmo po/ru/telegramopenwrt.po "$telegramopenwrtI18nSource"/usr/lib/lua/luci/i18n/telegramopenwrt.ru.lmo

mkdir -p "$telegramopenwrtI18nSource"/CONTROL/
cat << 'EOF' > "$telegramopenwrtI18nSource"/CONTROL/postinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF

cat << 'EOF' > "$telegramopenwrtI18nSource"/CONTROL/prerm
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
exit 0
EOF
chmod +x "$telegramopenwrtI18nSource/CONTROL/postinst"
chmod +x "$telegramopenwrtI18nSource/CONTROL/prerm"

cat << EOF > "$telegramopenwrtI18nSource"/CONTROL/control
Package: luci-i18n-telegramopenwrt-ru
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: luci-app-telegramopenwrt
Source: feeds/packages/luci-app-telegramopenwrt
SourceName: luci-app-telegramopenwrt
License: GPL-2.0
Section: luci
SourceDateEpoch: ${SOURCE_DATE_EPOCH}
Architecture: all
URL: https://github.com/alexwbaule/telegramopenwrt
Maintainer: Alex W. Baule
Description: Русский перевод для luci-app-telegramopenwrt
EOF

echo "Происходит сборка пакета русского перевода для telegramopenwrt, подождите…"
LC_ALL=C ./ipkg-build "$telegramopenwrtI18nSource/"

rm -rf po2lmo-src
rm -f po2lmo
rm -rf "$telegramopenwrtI18nSource"
rm -rf po
}

# ============================================================================
# Основной алгоритм
# ============================================================================
UpdateScript

compileTelegramopenwrtLuci
echo "Происходит сборка дополнения telegramopenwrt для LuCI, подождите…"
LC_ALL=C ./ipkg-build "$telegramopenwrtLuciSource/"
rm -rf "$telegramopenwrtLuciSource"

compileTelegramopenwrtI18n

rm -rf ipkg-build

echo ""
echo "=== Сборка завершена! ==="
echo ""
echo "Установите на роутере:"
echo "  opkg install telegram-openwrt_1.1.1-1_all.ipk"
echo "  opkg install luci-app-telegramopenwrt_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
echo "  opkg install luci-i18n-telegramopenwrt-ru_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
echo ""

while true; do
read -rp "Работа скрипта завершена. Удалить ли теперь и сам скрипт "$0"? [Д/н]: " answer
case "$answer" in
""|Д|д|Да|да|Y|y|Yes|yes)
rm -rf "$0"
exit 0
;;
Н|н|Нет|нет|N|n|No|no)
exit 0
;;
*)
echo "Неправильный ввод. Попробуйте еще раз."
continue
;;
esac
done
