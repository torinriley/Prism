# Render graph and execution planning

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

Every node has zero or more input node IDs and exactly one output texture descriptor. Source nodes
represent caller-owned images or textures; compute nodes represent one kernel dispatch. An edge is
therefore both a dependency and a resource flow.

```text
                      ┌─ blur horizontal ─ blur vertical ─┐
Input ─ Exposure ─────┤                                   ├─ unsharp combine ─ Output
                      └──────── original image ───────────┘
```

## Validation

Before GPU resources are touched, the graph rejects:

- missing or out-of-range outputs and dangling inputs;
- cycles and self-loops;
- compute nodes without inputs and source nodes with inputs;
- zero-sized resources;
- format mismatches and illegal size changes.

Resize is explicit about changing dimensions; ordinary pointwise and spatial passes require matching
input and output descriptors.

## Deterministic scheduling

`ExecutionPlan` uses Kahn's topological sort. When several nodes are ready, the smallest insertion ID
wins. Graph structure and insertion order therefore fully determine execution order; dictionary
iteration does not.

The planner records each resource's final reader. The graph output is pinned through the end. This
inclusive lifetime model prevents an output from aliasing an input read by the same dispatch.

## Physical resources

`ResourcePlan` walks execution order and reuses a compatible slot only after the previous occupant's
last use. A ten-stage chain consequently needs an input plus two alternating intermediate textures,
not eleven allocations. Branches retain additional slots only while their values are live.

Slots are leased from the shared texture pool as a group before encoding and returned after GPU
completion. They never return to the pool between nodes in one command buffer.

## Optimization passes

1. **Identity elimination** redirects consumers around mathematically neutral operations, but only
   when the descriptor is unchanged.
2. **Dead-node elimination** removes compute nodes not reachable from the output. This also removes
   work orphaned by identity elimination.
3. **Pointwise fusion** combines compatible linear runs into one kernel, provided each intermediate
   has one consumer. Branches, LUTs, spatial work, output boundaries and descriptor changes stop a
   run.

Fusion changes rounding: values no longer round to the intermediate texture format between fused
operations. Tests show this makes results closer to an unquantized Double reference, but it is
documented because fused and unfused output need not be bit-identical.

All passes are optional through `OptimizationOptions`, which makes correctness and performance
comparisons reproducible.
