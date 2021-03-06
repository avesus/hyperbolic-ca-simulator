#The purpose of this worker is to render bezier curves positions for Poincare tessellation.
#
{ContextDelegate} = require "./context_delegate.coffee"

{Tessellation} = require "../core/hyperbolic_tessellation.coffee"
M = require "../core/matrix3.coffee"

cellMatrices = null
tessellation = null

initialize = (n, m, newCellMatrices) ->
  tessellation = new Tessellation n, m
  cellMatrices = newCellMatrices


render = (viewMatrix) ->
  context = new ContextDelegate
  for m in cellMatrices
    tessellation.makeCellShapePoincare M.mul(viewMatrix,m), context
    context.take()

self.onmessage = (e) ->
  switch e.data[0]
    when "I"
      [n, m, matrices] = e.data[1]
      console.log "Init tessellation {#{n};#{m}}"
      initialize n, m, matrices
      postMessage ["I", [n,m]]
      
      shapes = render M.eye()
      postMessage ["R", shapes, 0]      
      
    when "R"
      id = e.data[2]
      shapes = render( e.data[1])
      postMessage ["R", shapes, id]
    else
      console.log "Unknown message: #{JSON.stringify e.data}"
  
  
