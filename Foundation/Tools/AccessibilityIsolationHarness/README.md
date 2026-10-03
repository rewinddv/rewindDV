# Accessibility isolation harness

This driver-free harness reproduces the RewindDV accessibility surfaces as
independent app processes. The final component of the bundle identifier selects
one of the modes declared by `IsolationMode`, including the original component
tests (`static`, `navigation`, `canvas`, `timeline`, `video`, and `combined`),
the reduced scroll tests, and `fixedscroll` for the repaired semantic section.

The harness never opens the DriverKit user client and contains no deck-control,
receive, ingest, archive, or system-extension activation code. It exists to
reduce a native accessibility-client failure without putting hardware state at
risk.

## macOS 26 reduction result

The failing composition is a native SwiftUI `GroupBox` nested in a
`ScrollView`. Inspecting that composition causes the computer-use helper to
abort in its transformed accessibility-tree code with an out-of-range
`Array.remove(at:)` reached through nested `Sequence.compactMap` calls.

The following surfaces were isolated and inspected successfully:

- static native controls;
- `NavigationSplitView`;
- static and 30 Hz animated `Canvas` meters;
- an `AVSampleBufferDisplayLayer` hosted by `NSViewRepresentable`;
- scrollable text, buttons, a picker, and a spacer; and
- `IsolationSection` inside `ScrollView`.

`scrollgroup` retains the minimal crashing composition as a regression fixture.
It must never be used in a hardware-connected RewindDV process. `fixedscroll`
proves the production replacement: a custom semantic section with a heading,
stable contained children, and no `GroupBox` accessibility transform.
