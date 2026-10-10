# Ask TypeSafe's Jev (System One) questions through OpenRouter.
#
#   just yesno  "<state>" "<question>"                       -> yes (84%) | no (96%) | unsure (42% yes)
#   just yes    "<state>" "<question>" && cmd                -> exit 0 on yes, 1 otherwise (for && chains)
#   just choose "<state>" "<question>" label1 label2 [...]   -> payments (100%)
#   just score  "<state>" "<question>" "rubric 0" "rubric 1" [...]  -> 2.65 / 3  ≈ excellent
#   just ask    request.json            # hand-written body; "-" reads stdin
#   just models
#
# <state> may be "-" to read it from stdin:
#   curl -s "$url" | just yesno - "Should I take an umbrella?"
# A state that parses as JSON is sent as structured state; anything else is sent as text.
# An empty state is refused, so a failed upstream command never gets "answered".
#
# Switches, placed before the recipe name:
#   raw=1       print the full JSON response instead of the one-line decision
#   verbose=1   also print model, tokens and cost on stderr
#   model=...   use another model id (default below)
# Needs OPENROUTER_API_KEY in the environment or in ./.env.
#
# Note on `just models`: observed 2026-10-10, the catalog listed only typesafe/jev-router,
# which /systemone rejected, while the unlisted typesafe/jev-1.13 worked.

set dotenv-load
set positional-arguments
set shell := ["bash", "-euo", "pipefail", "-c"]

model := "typesafe/jev-1.13"
raw := ""
verbose := ""
base := "https://openrouter.ai/api/v1"

self := just_executable() + " --justfile " + quote(justfile()) + " model=" + quote(model) + " raw=" + quote(raw) + " verbose=" + quote(verbose)

# Show the recipes and switches
default:
    @just --list --justfile "{{ justfile() }}"
    @printf '\nSwitches (put before the recipe name, e.g. just raw=1 yesno ...):\n'
    @printf '    raw=1       full JSON response instead of the one-line decision\n'
    @printf '    verbose=1   also print model, tokens and cost on stderr\n'
    @printf '    model=ID    model to use (default {{ model }})\n'
    @printf '\nState "-" reads stdin:  curl -s "$url" | just yesno - "Should I take an umbrella?"\n'

# Yes/no question.
[no-exit-message]
yesno state question:
    @st=$({{ self }} _state "$1") \
    && body=$(jq -cn --arg model "{{ model }}" --argjson state "$st" --arg q "$2" \
        '{model: $model, state: $state, questions: {answer: {type: "noul", instructions: $q}}}') \
    && {{ self }} _post "$body" single

# Yes/no as an exit code for `&&` chains: 0 when yes, 1 otherwise. The decision goes to stderr.
[no-exit-message]
yes state question:
    @st=$({{ self }} _state "$1") \
    && body=$(jq -cn --arg model "{{ model }}" --argjson state "$st" --arg q "$2" \
        '{model: $model, state: $state, questions: {answer: {type: "noul", instructions: $q}}}') \
    && {{ self }} _post "$body" exit

# Pick one of the given labels.
[no-exit-message]
choose state question +labels:
    @st=$({{ self }} _state "$1") \
    && body=$(jq -cn --arg model "{{ model }}" --argjson state "$st" --arg q "$2" --args \
        '{model: $model, state: $state, questions: {answer: {type: "choice", instructions: $q, criteria: ($ARGS.positional | map({(.): null}) | add)}}}' \
        -- "${@:3}") \
    && {{ self }} _post "$body" single

# Score against an ordered rubric (first entry is score 0). Needs at least two entries.
[no-exit-message]
score state question +rubric:
    @if [ "$#" -lt 4 ]; then echo "score needs at least two rubric entries" >&2; exit 2; fi; \
    st=$({{ self }} _state "$1") \
    && body=$(jq -cn --arg model "{{ model }}" --argjson state "$st" --arg q "$2" --args \
        '{model: $model, state: $state, questions: {answer: {type: "score", instructions: $q, criteria: $ARGS.positional}}}' \
        -- "${@:3}") \
    && {{ self }} _post "$body" single

# Send a hand-written request body (file path, or "-" for stdin). `model` is filled in if absent.
[no-exit-message]
ask file:
    @body=$(jq -c --arg model "{{ model }}" '.model //= $model' "$1") \
    && {{ self }} _post "$body" named

# List TypeSafe models in OpenRouter's catalog (may not match what /systemone accepts; see note at the top).
models:
    @curl -sS --fail-with-body "{{ base }}/models" | jq -r '.data[].id | select(startswith("typesafe/"))'

# Resolve a state argument: "-" reads stdin; valid JSON passes through, anything else becomes a JSON string; empty is refused.
[no-exit-message]
_state s:
    #!/usr/bin/env bash
    set -euo pipefail
    s="$1"; if [ "$s" = "-" ]; then s=$(cat); fi
    if [ -z "${s//[[:space:]]/}" ]; then
        echo "nothing to ask about: state is empty (did the command before the pipe fail?)" >&2
        exit 2
    fi
    out=$(jq -c . <<<"$s" 2>/dev/null) && [ -n "$out" ] || out=$(jq -cn --arg s "$s" '$s')
    printf '%s\n' "$out"

# POST a System One body. Layout "single" prints the bare decision; "named" prefixes each answer with its question name;
# "exit" prints the yes/no verdict on stderr and exits 0 for yes, 1 otherwise.
[no-exit-message]
_post body layout:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is not set (export it or put it in ./.env)}"
    status=0
    resp=$(curl -sS --fail-with-body "{{ base }}/systemone" \
        -H "Authorization: Bearer $OPENROUTER_API_KEY" \
        -H 'content-type: application/json' \
        -d "$1") || status=$?
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$resp" | jq . 2>/dev/null || printf '%s\n' "$resp"
        exit "$status"
    fi >&2
    if [ -n "{{ raw }}" ]; then
        printf '%s\n' "$resp" | jq .
        exit 0
    fi
    if [ "$2" = "exit" ]; then
        p=$(printf '%s\n' "$resp" | jq -r '.answers.answer.noul')
        verdict=$(printf '%s\n' "$resp" | jq -r '.answers.answer.noul | if . >= 0.65 then "yes (\(. * 100 | round)%)" elif . <= 0.35 then "no (\((1 - .) * 100 | round)%)" else "unsure (\(. * 100 | round)% yes)" end')
        echo "$verdict" >&2
        awk -v p="$p" 'BEGIN { exit (p >= 0.65 ? 0 : 1) }'
        exit $?
    fi
    printf '%s\n' "$resp" | jq -r --arg layout "$2" '
        def pct: . * 100 | round | tostring + "%";
        def decision:
            if .type == "noul" then
                (.noul as $p
                 | if $p >= 0.65 then "yes (\($p | pct))"
                   elif $p <= 0.35 then "no (\(1 - $p | pct))"
                   else "unsure (\($p | pct) yes)" end)
            elif .type == "choice" then "\(.choice) (\(.confidence | pct))"
            elif .type == "score" then
                ((.legend | length) - 1) as $max
                | (.score | round | tostring) as $k
                | "\(.score) / \($max)  ≈ \(.legend[$k] // $k)"
            else tojson end;
        .answers | to_entries[]
        | if $layout == "named" then "\(.key): \(.value | decision)" else (.value | decision) end'
    if [ -n "{{ verbose }}" ]; then
        printf '%s\n' "$resp" | jq -r '"[\(.model) in=\(.usage.input_tokens) out=\(.usage.output_tokens) cost=$\(.usage.cost // "?")]"' >&2
    fi
