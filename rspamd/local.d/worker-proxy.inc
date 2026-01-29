# Milter proxy configuration
# Allows Postfix to connect to Rspamd for spam filtering

bind_socket = "*:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
