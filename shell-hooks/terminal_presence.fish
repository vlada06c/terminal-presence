if not set -q TERMINAL_PRESENCE_DIR
    set -l hook_file (status filename)
    if test -n "$hook_file"
        set -gx TERMINAL_PRESENCE_DIR (path dirname (path dirname "$hook_file"))
    end
end

function __terminal_presence_preexec --on-event fish_preexec
    set -l status_file /tmp/terminal_presence_status
    if set -q TERMINAL_PRESENCE_STATUS_FILE
        set status_file $TERMINAL_PRESENCE_STATUS_FILE
    end

    printf 'shell=%s\n%s\n' fish "$argv[1]" > $status_file
end
