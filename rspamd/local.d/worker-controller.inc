# The controller worker: /stat, /learnspam, /learnham, and the web UI.
#
# The image ships `password = "q1"` and docker-compose.yml publishes 11334 on
# the host, so until this file existed anyone who could reach the port could
# retrain the Bayes classifier or read the statistics.
#
# The secret is not in the repo. Rspamd runs every config file through Jinja
# before parsing it and exposes `RSPAMD_*` environment variables as `env.*`, so
# the password comes from `RSPAMD_controller_password` in the environment and
# the `|pbkdf` filter turns it into a `$2$...` catena hash at startup -- the
# file on disk never holds the plaintext, and neither does `rspamadm
# configdump`.
#
# Without the variable set, the block is skipped and the image default stands.
# That is deliberate: an Rspamd that refuses to start because a variable is
# missing takes the mail server down with it, and compose already fails loudly
# (`${RSPAMD_PASSWORD:?...}`) before it gets that far.

bind_socket = "*:11334";

{% if env.controller_password %}
password = "{= env.controller_password|pbkdf =}";
enable_password = "{= env.controller_password|pbkdf =}";
{% endif %}
