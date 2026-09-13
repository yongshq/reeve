# Verifying a harness

`verified = false` means reeve refuses to dispatch. Here is how to earn a `true`.

## 1. Is it installed

```sh
bin/reeve-doctor
```

It must appear under "installed but NOT verified". If it does not, the `bin` key in the harness
file is wrong.

## 2. Which permission mode actually works unattended

This is the step people skip, and it is the step that matters. A hand that stops to ask a human
hangs forever and looks identical to a hand that is thinking. Probe the modes rather than trusting
their names:

```sh
cd "$(mktemp -d)"
for mode in <the modes your harness offers>; do
  rm -f probe.txt
  out=$(<harness-cli> -p --permission-mode "$mode" \
    "Use the Bash tool to run exactly: echo ok > probe.txt   Then reply with only FINISHED." 2>&1)
  [ -f probe.txt ] && r="BASH RAN" || r="bash blocked"
  printf '%-20s %-14s %s\n' "$mode" "$r" "$(printf '%s' "$out" | head -1)"
done
```

Pick the narrowest mode that prints `BASH RAN`. Editing files is not enough on its own: a hand has
to be able to run the repository's tests to know whether its own work is correct.

Results for claude 2.1.236, as an example of how differently these behave:

| mode | bash | note |
|---|---|---|
| `acceptEdits` | runs | no consent dialog. This is the one reeve uses |
| `auto` | runs | broader than a hand needs |
| `dontAsk` | **denied** | "do not ask" means deny. Everything reports blocked |
| `bypassPermissions` | runs in print mode | interactively raises a consent dialog defaulting to "No, exit", which kills an unattended hand |

## 3. Does an interactive launch reach a prompt

Print mode is not proof. A harness can behave in `-p` and still raise a full screen dialog in its
TUI, which is exactly what `bypassPermissions` does. Launch it for real in a pane and look:

```sh
bin/reeve-brief probe-<harness> <holding> --office scout
# fill the two seams with a trivial question
bin/reeve-dispatch probe-<harness> --harness <harness> --allow-unverified
bin/reeve-backend call capture "$(bin/reeve-status probe-<harness> --raw | grep target)" 400
```

You are checking three things: no dialog is waiting, the task prompt actually arrived, and the
harness process is in the pane's foreground.

## 4. Does it complete the loop

The errand must append `working:` and then `done:` to its status file, and a scout must produce a
report. If status lines never appear, the harness read the brief but ignored the reporting
protocol, and the office text needs to be plainer rather than the harness marked verified.

## 5. Then, and only then

Set `verified = true` and record in `source` what you tested and at which version. A harness
verified at one version is not verified forever, but a dated note is honest and a bare `true` is
not.
