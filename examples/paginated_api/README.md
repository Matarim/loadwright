# Paginated API

The case a seeded-scale sweep alone cannot see.

## The blind spot

An endpoint that paginates returns the same 25 records whether the table
holds 30 rows or 30,000.

Its query count is therefore **flat across every scale factor**. A tool that
detects N+1 by measuring slope against seeded rows reports it as perfectly
healthy — while it issues one query per returned record, on every single
request, in production, forever.

This is not a corner case. It is most well-built Rails APIs. Pagination is
the thing you are supposed to do, and it is what hides the problem.

## Two sweeps, one axis fixed in each

| Sweep | Varies | Holds fixed | Answers |
|---|---|---|---|
| **seed-scale** | rows in the table | page size (sends *no* parameter) | does query **cost** grow with table size? |
| **page-size** | the page-size parameter | seeded rows, at the maximum | does query **count** grow with records returned? |

Never both at once. If seeded rows and page size both change between cells, a
rise in query count cannot be attributed to either — the slope is
*unattributable*, which is worse than noisy because it looks like a result.

Two consequences fall out of the split, both deliberate:

- The seed-scale sweep sends **no page-size parameter at all**, so the
  endpoint is measured as clients actually call it. That is also what lets an
  *unpaginated* endpoint reveal its payload growth.
- The page-size sweep runs at **concurrency 1**, because
  queries-per-returned-record is a single-request property.

## Make the largest page reachable

```ruby
config.page_size_sweep = [5, 25, 100]
config.scale_factors   = [10, 100, 200]   # 200 >= 100
```

If the biggest scale factor is smaller than the biggest page size, the sweep
measures the same rows repeatedly and draws a flat line. Loadwright detects
this and **skips the page-size sweep with an explanation**, rather than
reporting the flat line as a clean result.

## What "flat" means, and what it does not

An endpoint that ignores your page-size parameter is reported as **unable to
vary result size** — not as flat. The distinction matters: flat-because-fixed
is a clean answer, and flat-because-ignored is no answer at all.

## The other half: payload growth

Query count is not query cost. One query can load ten thousand rows.

An endpoint whose response bytes track the table size is unbounded whatever
its query count does, and `missing_pagination` catches exactly that.
