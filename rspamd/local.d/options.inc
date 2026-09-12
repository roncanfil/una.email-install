# General options
local_addrs = [192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, fd00::/8, 169.254.0.0/16, fe80::/10];

# How often Rspamd re-reads an HTTP map. The default is 5 minutes, which is a
# long time to wait for a "block this sender" to take effect; multimap.conf
# pulls the sender rules from the web app over HTTP.
map_watch_interval = 1min;
