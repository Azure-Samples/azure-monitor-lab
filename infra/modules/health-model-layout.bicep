// =============================================================================
// Canvas layout engine for Azure Monitor health models.
//
// Templates give the engine the relationships they already declare and read
// each entity's canvasPosition from the result, so nobody places a card by hand:
//
//   import { layoutHealthModel } from '../modules/health-model-layout.bicep'
//   var canvas = layoutHealthModel(rootName, [], edges)       // edges: { parent, child }
//   ...
//   canvasPosition: canvas[entityName]
//
// Layout rules (the same ones the portal Designer's Arrange draws, but centred):
//   - One row per layer, 193 px apart. An entity sits one row below its deepest parent.
//   - Every leaf gets its own 250 px column, left to right in declared order, so no
//     two cards in a row overlap. Entities added later take the next free column and
//     do not move anything declared before them.
//   - A parent is centred over its first and last child.
//   - Siblings keep the order of their relationships. An entity with several parents
//     hangs under the deepest one, and its other relationships are drawn as lines.
//   - Entities without a relationship (pass them in `entities`) hang under the root,
//     after its declared children.
//   - The leftmost column is x 0 and the root is y 0, so no coordinate is negative.
//
// Relationships must not form a cycle. Bicep has no recursion, so each step is a
// pass over arrays, working from the root down or from the deepest layer up.
// =============================================================================

func columnWidth() int => 250
func rowHeight() int => 193

func sumOf(values array) int => reduce(values, 0, (total, value) => total + value)

func childrenOf(tree array, name string) array => filter(tree, e => e.parent == name)

// Every entity named by `entities` or by a relationship, root excluded, in declared order.
func entityNames(root string, entities array, edges array) array => filter(
  union(entities, map(edges, e => e.child), map(edges, e => e.parent)),
  name => name != root
)

func prepare(root string, nodes array, edges array) object => {
  root: root
  nodes: nodes
  edges: concat(
    edges,
    map(filter(nodes, n => !contains(map(edges, e => e.child), n)), n => { parent: root, child: n })
  )
}

// Layer = longest path from the root. Each pass can only raise a layer, so passes
// equal to the number of entities are enough.
func withLayers(s object) object => union(s, {
  layers: reduce(range(0, length(s.nodes)), { '${s.root}': 0 }, (layers, pass) => reduce(s.edges, layers, (current, e) => union(current, {
    '${e.child}': max(current[?e.child] ?? 0, (current[?e.parent] ?? 0) + 1)
  })))
})

func withDepth(s object) object => union(s, {
  depth: reduce(items(s.layers), 0, (deepest, layer) => max(deepest, layer.value))
})

// The layout tree: each entity keeps the first relationship that comes from the layer above it.
func firstPerChild(edges array) array => filter(edges, (e, i) => indexOf(map(edges, c => c.child), e.child) == i)

func withTree(s object) object => union(s, {
  tree: map(
    firstPerChild(filter(s.edges, e => s.layers[e.parent] == s.layers[e.child] - 1)),
    (e, i) => { parent: e.parent, child: e.child, order: i }
  )
})

// Columns a subtree needs, from the deepest layer up.
func withWidth(s object) object => union(s, {
  width: reduce(range(0, s.depth + 1), {}, (done, step) => union(done, toObject(
    filter(items(s.layers), layer => layer.value == s.depth - step),
    layer => layer.key,
    layer => max(1, sumOf(map(childrenOf(s.tree, layer.key), e => done[e.child])))
  )))
})

// First column of each subtree, from the root down: after the columns of its earlier siblings.
func withStart(s object) object => union(s, {
  start: reduce(range(1, s.depth), { '${s.root}': 0 }, (placed, layerIndex) => union(placed, toObject(
    filter(s.tree, e => s.layers[e.child] == layerIndex),
    e => e.child,
    e => placed[e.parent] + sumOf(map(filter(s.tree, t => t.parent == e.parent && t.order < e.order), t => s.width[t.child]))
  )))
})

func centreOver(children array, placed object) int => (placed[first(children).child] + placed[last(children).child]) / 2

func xOf(s object, placed object, name string) int => empty(childrenOf(s.tree, name))
  ? s.start[name] * columnWidth()
  : centreOver(childrenOf(s.tree, name), placed)

// Leaves take their column, parents centre over their children, from the deepest layer up.
func withX(s object) object => union(s, {
  x: reduce(range(0, s.depth + 1), {}, (placed, step) => union(placed, toObject(
    filter(items(s.layers), layer => layer.value == s.depth - step),
    layer => layer.key,
    layer => xOf(s, placed, layer.key)
  )))
})

func placements(s object) object => toObject(items(s.layers), layer => layer.key, layer => {
  x: s.x[layer.key]
  y: layer.value * rowHeight()
})

@export()
@description('Canvas positions { x, y } by entity name for the root, every entity in `entities` and every entity named in `edges` ({ parent, child } objects).')
func layoutHealthModel(root string, entities array, edges array) object => placements(withX(withStart(withWidth(withTree(withDepth(withLayers(prepare(
  root,
  entityNames(root, entities, edges),
  filter(edges, e => e.child != root && e.child != e.parent)
))))))))
