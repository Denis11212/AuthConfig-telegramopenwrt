#!/bin/sh

# Этот скрипт лишь умеет делать установочный ipk файл веб интерфейса LuCI для приложения Telegram Scripts for OpenWrt https://github.com/alexwbaule/telegramopenwrt. Соотвественно, для полноценной работы скрипта нужно поставить приложение https://github.com/alexwbaule/telegramopenwrt/releases/download/1.1.1/telegram-openwrt_1.1.1-1_all.ipk

# Из существенных недоработок и недоделок отмечу, что галочка автозапуска в веб интерфейсе Luci не работает. Так же при нажатии кнопки "применить изменения" в интерфейсе LuCI сами измненения хоть записываются в UCI файл настроек /etc/config/telegramopenwrt, но программа не перезапускается сама, соотвественно, перезапускать придётся вручную. Так же в веб интерфейсе не отображается статус работы службы telegramopenwrt, нет возможности перезапустить telegramopenwrt, а часть функционала вообще не реализована. Например, неплохо было бы добавить больше информативности к командам. Или, например, было бы классно реализовать поиск телевизоров Samsung в локальной сети, и потом вывод на них информации.
# По этой причине, при каждом изменении настроек в LuCI нужно нажать "применить", а потом перезапустить сервис командой "service telegramopenwrt restart".


telegramopenwrtLuciSource="telegramopenwrtLuciSource" # папка, в которой будет создаваться файловая система ipk установочника веб интерфейса


# Скачивание актуальной версии скрипта по сборке установочника
UpdateScript()
{
echo "Происходит загрузка скрипта для сборки ipk пакета ipkg-build, подождите…"
curl -Ls -O "https://github.com/openwrt/openwrt/raw/refs/heads/main/scripts/ipkg-build"
chmod +x ./ipkg-build
echo "Скрипт ipkg-build загружен"
}


compileTelegramopenwrtLuci() # Создание файлов и комплияция пакета для оболочки LuCI
{
mkdir -p "$telegramopenwrtLuciSource"/www/luci-static/resources/view/
	cat << 'EOF' > "$telegramopenwrtLuciSource"/www/luci-static/resources/view/telegramopenwrt.js	# Создание файла на языке JavaScript для отрисовки веб интерфейса.
'use strict';
'require form';

return L.view.extend({
    render: function () {
        var m, s, o;

        m = new form.Map('telegramopenwrt', 'Telegram Scripts for OpenWrt');

s = m.section(form.NamedSection, 'global', 'telegramopenwrt', 'Global parameters');
        o = s.option(form.Value, 'key', 'Bot token');
        o.description = `
<abbr title="Details in the official documentation"><a href="https://core.telegram.org/bots/api#authorizing-your-bot" target="_blank">Create a bot</a></abbr> via <a href="https://t.me/BotFather" target="_blank">@BotFather</a> and obtain an <abbr title="Example: 123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11">Bot token</abbr>. Then replace <code>[PUT YOUR BOT KEY HERE]</code> above with this Bot token.
`;

        o = s.option(form.Value, 'url', 'Bot URL API');
        o = s.option(form.Value, 'my_chat_id', 'Chat ID');
o.description = `
Get you <abbr title="Details in the official documentation"><a href="https://core.telegram.org/api/bots/ids#chat-ids" target="_blank">Chat ID</a></abbr>. Then replace <code>[PUT ID OF THE CHAT THAT YOU START WITH BOT]</code> above with you <abbr title="Example: 123456789">Chat ID</abbr>. In order for the bot to be able to communicate with you, you must send one message to the bot from the account whose Chat ID you specified.
`;

        o = s.option(form.Value, 'timeout', 'Connection Timeout');
        o = s.option(form.Value, 'ignored_macaddrs_file', 'MAC Addresses Ignore List File');

s = m.section(form.NamedSection, 'ipcam', 'telegramopenwrt', 'IP Camera Configuration');
        o = s.option(form.Value, 'header_auth', 'HTTP Authentication Header Value');
        o = s.option(form.Value, 'ipaddr', 'Camera IP or Hostname');
        o = s.option(form.Value, 'user', 'Camera Username');
        o = s.option(form.Value, 'passwd', 'Camera Password');

s = m.section(form.NamedSection, 'smtp', 'telegramopenwrt', 'SMTP Email Notifications');
        o = s.option(form.Value, 'from', 'E-Mail Sender Address');
        o = s.option(form.Value, 'to', 'E-Mail Recipient Address');

s = m.section(form.NamedSection, 'television', 'telegramopenwrt', 'Television Settings');
        o = s.option(form.Value, 'ipaddr', 'TV Device IP Address');
        o = s.option(form.Value, 'sender_name', 'Sender Name');
        o = s.option(form.Value, 'sender_number', 'Sender Number');
        o = s.option(form.Value, 'receiver_name', 'Receiver Name');
        o = s.option(form.Value, 'receiver_number', 'Receiver Number');

s = m.section(form.NamedSection, 'proxy', 'telegramopenwrt', 'Proxy Server');
        o = s.option(form.ListValue, 'http', 'Enable HTTP Proxy');
        o.value('true', 'True');
        o.value('false', 'False');
        o = s.option(form.ListValue, 'https', 'Enable HTTPS Proxy');
        o.value('true', 'True');
        o.value('false', 'False');




o = s.option(form.DummyValue, '_toggle_btn', 'Commands for Bot');
o.rawhtml = true;
o.cfgvalue = function () {
    return `
        <button class="btn" onclick="
            var btnText = this.textContent.trim();
            var section = document.getElementById('advanced_section');

            if(section.style.display === 'none'){
                section.style.display = 'block';
                this.textContent = 'Close';
            } else{
                section.style.display = 'none';
                this.textContent = 'Show';
            }
        ">Open</button>

        <div id="advanced_section" style="display:none; margin-top:10px;">
<p><b>These commands can be sent to the bot, I listed them for convenience. The list of commands can also be obtained in Telegram, if you send the bot the message <code>/start</code>:</b><p/>

<p><code>/cam_movie</code> Record 25 seconds of a camIP and send it.</p>
<p><code>/cam_mv</code> Move the camera around.</p>
<p><code>/cam_shot</code> Get a picture from the camera.</p>
<p><code>/cam_vdo</code> Get a 25 seconds recording from a camIP.</p>
<p><code>/chromego_add</code> Include a word to be used in ChromeGo permissions (block URLs/Youtube channels/etc.).</p>
<p><code>/chromego_del</code> Remove a word from ChromeGo permissions (block URLs/Youtube channels/etc.).</p>
<p><code>/chromego_list</code> List all ChromeGo permissions (block URLs/Youtube channels/etc.).</p>
<p><code>/fw_add</code> Block a hostname using a deny rule in the firewall; optionally specify blocking hours between 23:00–08:00.</p>
<p><code>/fw_delete</code> Remove a hostname from a deny firewall rule; if no hostname specified, removes all rules created by this bot.</p>
<p><code>/fw_disable</code> Disable a firewall rule.</p>
<p><code>/fw_enable</code> Enable a firewall rule.</p>
<p><code>/fw_list</code> List all firewall rules.</p>
<p><code>/fwr_disable</code> Disable a redirect firewall rule.</p>
<p><code>/fwr_enable</code> Enable a redirect firewall rule.</p>
<p><code>/fwr_list</code> List all redirect firewall rules.</p>
<p><code>/fw_unblock</code> Remove a hostname from a deny firewall rule; if no hostname specified, removes all rules created by this bot.</p>
<p><code>/get_ip</code> Get the WAN IP Address.</p>
<p><code>/get_mac</code> Get the organization owning the MAC address.</p>
<p><code>/get_ping</code> Ping an address or host, returns "Up" or "Down".</p>
<p><code>/get_uptime</code> Return the uptime of this device.</p>
<p><code>/hst_list</code> Get DHCP leased hosts; if a specific hostname provided, searches only for that hostname.</p>
<p><code>/ignoredmac_add</code> Add a MAC address to the allowlist to prevent notifications.</p>
<p><code>/ignoredmac_list</code> Show the list of ignored MAC addresses which won't trigger notifications.</p>
<p><code>/interface_down</code> Shut down an interface by its name.</p>
<p><code>/interface_restart</code> Restart an interface by its name.</p>
<p><code>/interfaces_list</code> Get interfaces configuration.</p>
<p><code>/interface_up</code> Start up an interface by its name.</p>
<p><code>/lights</code> Turn on/off household lights.</p>
<p><code>/msg_tv</code> Send a message to a Samsung TV.</p>
<p><code>/netstat</code> Print network statistics in established, closed, and timed wait state.</p>
<p><code>/opkg_install</code> Install a package via OPKG.</p>
<p><code>/opkg_update</code> Update the list of available packages.</p>
<p><code>/ping_udp</code> Create a UDP packet to punch a hole through NAT firewalls at your ISP.</p>
<p><code>/proc_list</code> List all running processes.</p>
<p><code>/proc_restart</code> Restart a process in init.d.</p>
<p><code>/proc_start</code> Start a process in init.d.</p>
<p><code>/proc_stop</code> Stop a process in init.d.</p>
<p><code>/proxy_disable</code> Disable HTTP and/or HTTPS proxy.</p>
<p><code>/proxy_enable</code> Enable HTTP and/or HTTPS proxy.</p>
<p><code>/proxy_list</code> List enabled proxy rules.</p>
<p><code>/reboot</code> Reboot the router.</p>
<p><code>/start</code> Display this help menu!</p>
<p><code>/swports_list</code> List switch ports with their current states.</p>
<p><code>/wifi_disable</code> Disable a wireless device's radio.</p>
<p><code>/wifi_enable</code> Enable a wireless device's radio.</p>
<p><code>/wifi_list</code> List all wireless devices.</p>
<p><code>/wifi_restart</code> Restart a wireless device's radio.</p>
<p><code>/wll_list</code> Get a list of Wi-Fi clients currently connected to this device.</p>
        </div>
    `;
};


return m.render();
    }
});
EOF

mkdir -p "$telegramopenwrtLuciSource"/usr/share/rpcd/acl.d/
	cat << 'EOF' > "$telegramopenwrtLuciSource"/usr/share/rpcd/acl.d/luci-app-telegramopenwrt.json	# Создание структуры доступа к разным действиям и папкам для JavaScript файла программы.
{
        "luci-app-telegramopenwrt": {
                "description": "Grant access to cat Telegram Scripts for OpenWrt config",
                "read": {
                        "uci": [
                                "telegramopenwrt"
                        ]
                },
                "write": {
                        "uci": [
                                "telegramopenwrt"
                        ]
                }
        }
}
EOF

mkdir -p "$telegramopenwrtLuciSource"/usr/share/luci/menu.d/
	cat << 'EOF' > "$telegramopenwrtLuciSource"/usr/share/luci/menu.d/luci-app-telegramopenwrt.json	# Создание структуры меню, т.е. в каком разделе LuCI искать программу.
{
        "admin/services/telegramopenwrt": {
                "title": "Telegram Scripts",
                "action": {
                        "type": "view",
                        "path": "telegramopenwrt"
                },
                "depends": {
                        "acl": [ "luci-app-telegramopenwrt" ],
                        "uci": { "telegramopenwrt": true }
                }
        }
}
EOF

mkdir -p "$telegramopenwrtLuciSource"/CONTROL/
	cat << EOF > "$telegramopenwrtLuciSource"/CONTROL/control	# Далее нужно внимательно проверить, верна ли информация, указанная ниже в файле control. Обязательно должны присутсвовать разделы Package, Version, Architecture, Maintainer, Description, хотя насчёт Description и Maintainer я не уверен, впрочем, может и ещё меньше можно оставить полей. Но лишняя информация вряд-ли повредит, особенно если она верно указана. Скрипт ipkg-build умеет заполнять Installed-Size автоматически. Так же можно использовать ещё в control файле ipk пункт Depends:, в котором можно указазать от каких других пакетов зависит данный пакет для своей работы. Ну и вместо <http://www.alexwb.com.br>, возможно, лучше бы указать email или другой какой-то способ связи. SourceDateEpoch: как я понял, это в формате Unix time время крайнего измнения исходного кода.
Package: luci-app-telegramopenwrt
Version: 1.0
Depends: telegram-openwrt
Source: feeds/packages/luci-app-telegramopenwrt
SourceName: luci-app-telegramopenwrt
License: GPL-2.0
LicenseFiles: LICENSE
Section: luci
SourceDateEpoch: 1694191255
Architecture: all
URL: https://github.com/alexwbaule/telegramopenwrt
Maintainer: Alex W. Baulé <http://www.alexwb.com.br>
Installed-Size: 
Description: Telegram for use in openwrt. Its a web interface for BOT that executes selected commands in your router.
EOF
}


# Основной алгоритм действий скрипта!

UpdateScript

# Сборка пакета для LuCI
compileTelegramopenwrtLuci # Делаем структуру папок и файлов для модуля к LuCI
echo "Происходит сборка дополнения telegramopenwrt для LuCI, подождите…"
./ipkg-build "$telegramopenwrtLuciSource/"
rm -rf "$telegramopenwrtLuciSource" # Удаление папки, используемой для сборки LuCI дополнения за ненадобностью.

rm -rf ipkg-build # Удаление файла создаения IPK файлов. Но сам скрипт и созданные файлы для разных архитектур остаются.

#Диалог выхода из программы с предложением удалить файлы.
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
