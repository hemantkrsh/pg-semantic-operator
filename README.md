# pg-semantic-operator

A small Postgres demo that adds a `@@?` operator. It asks a local model a yes/no question about a piece of text.

```sql
SELECT * FROM user_actions
WHERE action_log @@? 'Is the user trying to cancel their account?';
```

## How it works

There are two containers:

- `postgres-db`: Postgres 16 with PL/Python. `init.sql` creates the operator.
- `strands-model`: runs `StrandsAgents/strands-decider-2B-hobson-v19` over HTTP on port 8000.

For each row, Postgres sends the text and the question to the model. The model returns a score from 0 to 1. The operator returns true if the score is at least the threshold (0.5 by default).

Results are saved in the `strands_cache` table. The same text and question are only sent to the model once.

## Run it

```sh
docker compose up -d --build
```

The first start downloads the model weights, which can take a few minutes. After that you can run offline:

```sh
HF_HUB_OFFLINE=1 docker compose up -d
```

Run the demo queries:

```sh
docker compose exec postgres-db psql -U systemone -d systemone -f /demo/demo_queries.sql
```

## Functions

| Name | Returns |
| --- | --- |
| `text @@? question` | `true` if the model says yes |
| `strands_decide(text, question)` | Same as `@@?` |
| `strands_score(text, question)` | The raw score, from 0 to 1 |

## Settings

Change these per session with `SET`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `strands.threshold` | `0.5` | Minimum score for a yes |
| `strands.use_cache` | `on` | Read and write `strands_cache` |
| `strands.timeout_s` | `30` | HTTP timeout in seconds |
| `strands.endpoint` | `http://strands-model:8000/v1/systemone` | Model URL |

The default database user, password and name are all `systemone`. Set `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB` in a `.env` file to change them.

## Notes

- Each uncached row is one HTTP call, so filter with normal `WHERE` clauses first.
- `init.sql` only runs on an empty database. Run `docker compose down -v` to start over.
