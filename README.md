<p align="center">
  <img src="assets/hero.png" alt="Messy inputs flow into a pipe labelled jev and come out as one clear decision" width="100%">
</p>

<h1 align="center">jev</h1>

<p align="center"><em>Pipe anything in. Get one decision out.</em></p>

`jev` is a single [justfile](https://just.systems) that asks [TypeSafe's Jev](https://docs.typesafe.ai/concepts/system-one) model a question about whatever you give it and prints one line you can act on.

```
$ curl -s "https://api.open-meteo.com/v1/forecast?latitude=50.08&longitude=14.44&hourly=precipitation_probability&forecast_days=1" \
    | just yesno - "Should I take an umbrella today?"
yes (87%)
```

Jev is not a chatbot. It never writes prose. It answers exactly three kinds of question, each in a few hundred milliseconds for a few thousandths of a cent:

| Ask | Get |
| --- | --- |
| `yesno`  — is this X? | `yes (99%)`, `no (91%)`, or `unsure (57% yes)` |
| `choose` — which of these labels? | `payments (100%)` |
| `score`  — where on this rubric? | `2.58 / 3  ≈ excellent` |

## Install

You need `just`, `curl` and `jq`, plus an [OpenRouter](https://openrouter.ai/keys) API key.

```sh
# macOS            # Arch                 # Debian / Ubuntu 24.04+      # anywhere with Rust
brew install just  # sudo pacman -S just  # sudo apt install just        # cargo install just
```

```sh
git clone https://github.com/yfe404/just-jev && cd just-jev
export OPENROUTER_API_KEY=sk-or-...        # or: cp .env.example .env and edit it
just yesno "It is pouring outside." "Should I take an umbrella?"
```

To call it from any directory, give it an alias:

```sh
alias jev='just --justfile ~/src/just-jev/justfile'
jev yesno "It is pouring outside." "Should I take an umbrella?"
```

## Use

```
just yesno  "<state>" "<question>"
just yes    "<state>" "<question>" && ...      # same, as an exit code
just choose "<state>" "<question>" label1 label2 [label3 ...]
just score  "<state>" "<question>" "rubric 0" "rubric 1" ["rubric 2" ...]
just ask    request.json                 # hand-written body with several named questions
just models
```

The **state** is whatever you want a decision about: a sentence, a file, a JSON blob. Pass `-` to read it from stdin, which is how it joins a pipeline. JSON is sent as structured data, anything else as text, and empty input is refused so a failed command upstream never gets "answered".

Switches go before the recipe name:

```
just raw=1 yesno ...        # the full JSON response instead of one line
just verbose=1 yesno ...    # also print model, tokens and cost on stderr
just model=ID yesno ...     # another model id (default: typesafe/jev-1.13)
```

## Examples

All outputs below are real, captured on 2026-10-10. Yours will differ by a few points, because every call is a fresh decision.

### Pack an umbrella

A public weather endpoint becomes a plain decision you can put in a morning script.

```sh
curl -s "https://api.open-meteo.com/v1/forecast?latitude=50.08&longitude=14.44&current=precipitation,rain&hourly=precipitation_probability&forecast_days=1" \
  | just yesno - "Should I take an umbrella today?"
```
```
yes (89%)
```

### What is Hacker News about today?

Ten headlines in, one label out.

```sh
curl -s 'https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=10' | jq '[.hits[].title]' \
  | just choose - "What is the front page mostly about today?" programming science business politics culture
```
```
programming (65%)
```

### Tag a note

Your own notes become structured data without a separate app.

```sh
just choose "Renew my passport before the summer trip; check visa rules too." "Which tag fits this note?" todo idea reference journal
```
```
todo (100%)
```

### Triage a ticket

A human sentence becomes a routing decision the next shell step can consume.

```sh
just choose "Card charged twice; the customer wants the duplicate reversed." "Where should this ticket go?" billing bug security docs
```
```
billing (100%)
```

### Did the ground shake?

Jev reads numbers in JSON, not just words.

```sh
curl -s https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson \
  | jq -c '[.features[].properties | {mag, place}]' \
  | just yesno - "Was there an earthquake of magnitude 4 or more?"
```
```
no (99%)
```

## Combining decisions

The output is one line and the exit code is meaningful, so Jev composes with `&&`, `case`, loops and `sort` like any other Unix tool.

### Gate a command

`just yes` prints nothing on stdout and exits 0 for yes, 1 otherwise. The verdict goes to stderr so you still see why.

```sh
git log -1 --format=%s | just yes - "Is this commit message a release?" && echo "-> tagging" || echo "-> not a release, skipping"
```
```
no (97%)
-> not a release, skipping
```

### Route with `case`

A choice feeds an ordinary `case` statement, so the rest of the workflow stays visible in the script.

```sh
case $(git diff --name-only HEAD | just choose - "Which workflow should run for these changed files?" docs tests release) in
  docs*)    echo "-> building docs" ;;
  tests*)   echo "-> running tests" ;;
  release*) echo "-> cutting a release" ;;
esac
```
```
-> running tests
```

### Classify a list into a table

One decision per line. Here it is the files of this repo, but it could be emails, filenames or log lines.

```sh
for f in README.md justfile .env.example .gitignore; do
  printf '%-14s ' "$f"; just choose "$(head -c 1500 "$f")" "What kind of file is this?" docs code config
done
```
```
README.md      docs (97%)
justfile       code (89%)
.env.example   config (97%)
.gitignore     config (100%)
```

### Score, then sort

A score is a number, so `sort` and `awk` work on it. Here Jev ranks feature ideas for this very tool.

```sh
for idea in "cache weather data" "add an export button" "rewrite in Rust" "fix the typo in the README"; do
  printf '%s\t%s\n' "$(just score "$idea" "How valuable is this for a tiny shell tool?" low medium high excellent)" "$idea"
done | sort -rn
```
```
1.58 / 3  ≈ high	rewrite in Rust
1.39 / 3  ≈ medium	cache weather data
1.09 / 3  ≈ medium	add an export button
0.41 / 3  ≈ low	fix the typo in the README
```

### Several questions in one call

Write the request yourself and `just ask` sends it. One round trip, one line per question.

```sh
cat > ticket.json <<'EOF'
{"state": "Card charged twice; the customer wants the duplicate reversed today.",
 "questions": {
   "team":   {"type": "choice", "instructions": "Who should handle this?", "criteria": {"billing": null, "engineering": null, "support": null}},
   "urgent": {"type": "noul",   "instructions": "Does this need action today?"},
   "mood":   {"type": "score",  "instructions": "How upset is the customer?", "criteria": ["calm", "annoyed", "angry"]}}}
EOF
just ask ticket.json
```
```
team: billing (80%)
urgent: yes (94%)
mood: 0.93 / 2  ≈ annoyed
```

## Philosophy

Jev gives shell scripts a small decision primitive: hand it text or JSON, ask one typed question, get one typed answer. A yes/no gates a command, a choice selects a route, a score ranks items. Because the result is one line, Jev sits beside `curl`, `jq`, loops, pipes and `case` statements, and the workflow stays visible and made of the Unix tools you already use.

It is deliberately not a chatbot. If you need a paragraph, use a language model. If you need a decision, ask Jev.

## Latency and cost

Measured from this justfile on 2026-10-10, five runs per row, Prague to OpenRouter. Cost is what OpenRouter reported in the response.

| Input | Tokens | Median | Per call |
| --- | ---: | ---: | ---: |
| One sentence | 277 | 400 ms | $0.000012 |
| A day of hourly weather JSON | 1,041 | 326 ms | $0.000044 |
| A 12 KB README | 3,668 | 460 ms | $0.00015 |

A bare `curl` of the one-sentence case took 316 ms, so the justfile and `jq` add under 100 ms. At these prices a thousand decisions on short inputs cost about one cent.

## How it works

Each recipe builds a System One request with `jq`, POSTs it to OpenRouter's `/api/v1/systemone` route with your key, and formats the typed answer. There is no code beyond the justfile. Read it; it is short.

The yes/no probability is printed as `yes` above 65%, `no` below 35%, and `unsure` in between. Scores show the expected value, the rubric maximum, and the nearest rubric label as Jev returned it.

## License

MIT
