# acme — fixture org source for anfs tests

A stand-in for a real org repo (lgat): one source holding every resource kind, so a single
`anfs src add` + `anfs install acme` exercises all four tools.

| Dir | Tool | What |
| --- | --- | --- |
| `packages/hello` | ppm | a script stowed to `~/.local/bin/acme-hello`, no dependencies |
| `packages/acme-infra` | ppm | depends on `opentofu`, which lives in another source (pdt) |
| `containers/whoami` | pcm | a tiny HTTP service, following pcm's conventions |
| `containers/inspector` | pcm | an idle box with every source mounted (the `anfs-sources` mount set) |
| `skills/acme-hello` | psm | one skill |
| `spaces/org`, `spaces/tech` | wsm | `tech` depends on `org` |

Nothing here needs credentials: the space repo is a public https URL.
