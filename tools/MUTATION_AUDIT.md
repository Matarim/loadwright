# Mutation audit

A standing check that the safety-critical specs actually test what they claim.

    bundle exec rake mutation_audit

It breaks one safety behaviour at a time and confirms the corresponding spec goes
RED. A behaviour whose spec stays green when the behaviour is removed is a spec
testing nothing — the state 22 of the guard's examples were in before
`EnvironmentGuard` took an injectable `rails_env`, which nobody noticed because
the suite was green.

## It never touches your working tree

The audit copies the repository to a temp directory and mutates the copy.

This is not caution for its own sake. The first version mutated files in place and
restored them in an `ensure`, which works right up until the process is killed —
and it was, by a timeout. It left `lib/loadwright/coverage.rb` **zero bytes** and
three orphaned Puma processes holding the fixture database open. A tool whose
failure mode is "silently disables a safety check in your working tree" has no
business being pointed at a safety suite. An interrupted run can now lose nothing
but a temp directory.

For the same reason it targets **narrow spec files** and never the end-to-end spec:
that one boots a real server per run, and a killed audit would orphan every one.

## It refuses to run on a dirty working tree

    ALLOW_DIRTY=1 bundle exec rake mutation_audit    # when you genuinely mean it

The audit only mutates a throwaway copy, so it cannot damage your files directly.
It refuses anyway, and the reason is worth stating rather than just enforcing.

Recovery from a problem in destructive tooling tends to be destructive too. Cleaning
up after the in-place version of this script, a `git checkout -- lib/` scoped one
directory too wide wiped two completed pieces of work. Nothing was lost, because
they were small enough to redo — but only for that reason. Had there been a commit
to return to, none of the recovery would have been needed at all.

The audit's job is to prove the safety specs are real. A tool that can cost you
uncommitted work while doing it undermines its own purpose. Commit first; the commit
is what makes recovery free.

## Every mutation proves it changed something first

The failure mode of a hand-rolled audit is a mutation that does not actually change
behaviour. The spec stays green, and it *looks* like a coverage gap.

That happened on the first run. The Layer 1b adjacency mutation inserted a dead
line and returned the same value, so it scored as `STAYED_GREEN` against a spec
that was in fact fine. It was caught by reading the diff — which is not a method,
and next time the no-op may not be obvious.

So every mutation carries a `proof`: a small expression evaluated in a fresh
subprocess against the mutated copy, printing one observable value. The audit runs
it before and after applying the mutation and **refuses to score a mutation whose
proof value did not change**, reporting `NO_OP` instead. That is a defect in the
audit, not a pass for the spec.

Two mutations use `proof: :source_text` instead, where the observable effect is on
a generated file rather than on runtime behaviour.

## Reading the output

| Label | Meaning |
|---|---|
| `RED` | The mutation changed behaviour and the spec caught it. What you want. |
| `GREEN!` | The mutation changed behaviour and the spec did **not** notice. A spec testing nothing — fix the spec. |
| `NO-OP` | The mutation changed no observable behaviour. The audit is wrong here, not the spec — write a real mutation. |
| `ANCHOR?` | The source no longer contains the text the mutation patches. The code moved; update the mutation. |

## When to run it

After changing anything in `safety/`, the contention guard, the validity gate, the
coverage model, or the seeder's cleanup — and before believing a green suite means
those behaviours are still enforced.
