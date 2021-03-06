"use strict"

#Core hyperbolic group compuatation library
{unity} = require "../core/vondyck_chain.coffee"
{ChainMap} = require "../core/chain_map.coffee"
{RegularTiling} = require "../core/regular_tiling.coffee"
{evaluateTotalisticAutomaton} = require "../core/cellular_automata.coffee"

{stringifyFieldData, parseFieldData, importField, randomFillFixedNum, exportField, randomStateGenerator} = require "../core/field.coffee"
{GenericTransitionFunc, BinaryTransitionFunc,DayNightTransitionFunc, parseTransitionFunction} = require "../core/rule.coffee"
M = require "../core/matrix3.coffee"

#Application components
{Animator} = require "./animator.coffee"
{MouseToolCombo} = require "./mousetool.coffee"
{Navigator} = require "./navigator.coffee"
{FieldObserver} = require "./observer.coffee"
{GenerateFileList, OpenDialog, SaveDialog} = require "./indexeddb.coffee"
#{FieldObserverWithRemoreRenderer} = require "./observer_remote.coffee"

#Misc utilities
{E, getAjax, ButtonGroup, windowWidth, windowHeight, documentWidth, removeClass, addClass, ValidatingInput} = require "./htmlutil.coffee"
{DomBuilder} = require "./dom_builder.coffee"
{parseIntChecked, parseFloatChecked} = require "../core/utils.coffee"
{parseUri} = require "./parseuri.coffee"
{getCanvasCursorPosition} = require "./canvas_util.coffee"
C2S = require "../ext/canvas2svg.js"
#{lzw_encode} = require "../ext/lzw.coffee"
require "../ext/polyfills.js"
require "../core/acosh_polyfill.coffee"

{GhostClickDetector} = require "./ghost_click_detector.coffee"
MIN_WIDTH = 100

minVisibleSize = 1/100
canvasSizeUpdateBlocked = false
randomFillNum = 2000
randomFillPercent = 0.4

class DefaultConfig
  getGrid: -> [7,3]
  getCellData: -> ""
  getGeneration: -> 0
  getFunctionCode: -> "B 3 S 2 3"
  getViewBase: -> unity
  getViewOffset: -> M.eye()
  
class UriConfig
  constructor: ->
    @keys = parseUri(""+window.location).queryKey
    
  getGrid: ->  
    if @keys.grid?
      try
        match = @keys.grid.match /(\d+)[,;](\d+)/
        throw new Error("Syntax is bad: #{@keys.grid}") unless match
        n = parseIntChecked match[1]
        m = parseIntChecked match[2]
        return [n,m]
      catch e
        alert "Bad grid paramters: #{@keys.grid}"
    return [7,3]
  getCellData: ->@keys.cells
  getGeneration: ->
    if @keys.generation?
      try
        return parseIntChecked @keys.generation
      catch e
        alert "Bad generationn umber: #{@keys.generation}"
    return 0
        
  getFunctionCode: ->
    if @keys.rule?
      @keys.rule.replace /_/g, ' '
    else
      "B 3 S 2 3"
      
  getViewBase: ->
    return unity unless @keys.viewbase?
    RegularTiling::parse @keys.viewbase
    
  getViewOffset: ->
    return M.eye() unless @keys.viewoffset?
    [rot, dx, dy] = (parseFloatChecked part for part in @keys.viewoffset.split ':')
    M.mul M.translationMatrix(dx, dy), M.rotationMatrix(rot)
    
class Application
  constructor: ->
    @tiling = null
    @observer = null
    @navigator = null
    @animator = null
    @cells = null
    @generation = 0
    @transitionFunc = null
    @lastBinaryTransitionFunc = null
    
    #@ObserverClass = FieldObserverWithRemoreRenderer
    @ObserverClass = FieldObserver
    @margin = 16 #margin pixels
    
  setCanvasResize: (enable) -> canvasSizeUpdateBlocked = enable
  getCanvasResize: -> canvasSizeUpdateBlocked
  redraw: -> redraw()
  getObserver: -> @observer
  drawEverything: -> drawEverything canvas.width, canvas.height, context
  uploadToServer: (name, cb) -> uploadToServer name, cb
  getCanvas: -> canvas
  getTransitionFunc: -> @transitionFunc

  getMargin: -> if @observer.isDrawingHomePtr then @margin else 0
  setShowLiveBorders: (isDrawing)->
    @observer.isDrawingLiveBorders = isDrawing
    redraw()
    
  setDrawingHomePtr: (isDrawing)->
    @observer.isDrawingHomePtr = isDrawing
    redraw()
    if localStorage?
      localStorage.setItem "observer.isDrawingHomePtr", if isDrawing then "1" else "0"
      console.log "store #{isDrawing}"
      
  #Convert canvas X,Y coordinates to relative X,Y in (0..1) range
  canvas2relative: (x,y) ->
    s = Math.min(canvas.width, canvas.height) - 2*@getMargin()
    isize = 2.0/s
    [(x - canvas.width*0.5)*isize, (y - canvas.height*0.5)*isize]
    
  initialize: (config = new DefaultConfig)->
    [n,m] = config.getGrid()
    @tiling = new RegularTiling n, m
    
    cellData = config.getCellData()
    if cellData
      console.log "import: #{cellData}"
      @importData cellData
    else
      @cells = new ChainMap
      @cells.put unity, 1
    
    @observer = new @ObserverClass @tiling, minVisibleSize, config.getViewBase(), config.getViewOffset()
    if (isDrawing=localStorage?.getItem('observer.isDrawingHomePtr'))?
      isDrawing = isDrawing is '1'
      E('flag-origin-mark').checked = isDrawing
      @observer.isDrawingHomePtr = isDrawing
      console.log "restore #{isDrawing}"
    else
      @setDrawingHomePtr E('flag-origin-mark').checked
      @setShowLiveBorders E('flag-live-borders').checked
      
    @observer.onFinish = -> redraw()

    @navigator = new Navigator this
    @animator = new Animator this
    @paintStateSelector = new PaintStateSelector this, E("state-selector"), E("state-selector-buttons")

    @transitionFunc = parseTransitionFunction config.getFunctionCode(), application.tiling.n, application.tiling.m
    @lastBinaryTransitionFunc = @transitionFunc
    @openDialog = new OpenDialog this
    @saveDialog = new SaveDialog this
    @svgDialog = new SvgDialog this

    @ruleEntry = new ValidatingInput E('rule-entry'),
      ((ruleStr) =>
        console.log "Parsing TF {@tiling.n} {@tiling.m}"
        parseTransitionFunction ruleStr, @tiling.n, @tiling.m),
      ((rule)->""+rule),
      @transitionFunc 
      
    @ruleEntry.onparsed = (rule) => @doSetRule()
    
    @updateRuleEditor()
    @updateGridUI()
    
  updateRuleEditor: ->
    switch @transitionFunc.getType()
      when "binary"
        E('controls-rule-simple').style.display=""
        E('controls-rule-generic').style.display="none"
        
      when "custom"
        E('controls-rule-simple').style.display="none"
        E('controls-rule-generic').style.display=""
        
      else
        console.dir @transitionFunc
        throw new Error "Bad transition func"
        
  doSetRule: ->
    if @ruleEntry.message?
      alert "Failed to parse function: #{@ruleEntry.message}"
      @transitionFunc = @lastBinaryTransitionFunc ? @transitionFunc
    else
      console.log "revalidate"
      @ruleEntry.revalidate()
      @transitionFunc = @ruleEntry.value
      @lastBinaryTransitionFunc = @transitionFunc
    @paintStateSelector.update @transitionFunc
      
    console.log @transitionFunc
    
    E('controls-rule-simple').style.display=""
    E('controls-rule-generic').style.display="none"

  setGridImpl: (n, m)->
    @tiling = new RegularTiling n, m
    #transition function should be changed too.

    if @transitionFunc?
      @transitionFunc = @transitionFunc.changeGrid @tiling.n, @tiling.m
    
    @observer?.shutdown()
    
    oldObserver = @observer
    @observer = new @ObserverClass @tiling, minVisibleSize    
    @observer.isDrawingHomePtr = oldObserver.isDrawingHomePtr
    
    @observer.onFinish = -> redraw()
    @navigator?.clear()
    doClearMemory()
    doStopPlayer()
    @updateGridUI()
    
  updateGridUI: ->
    E('entry-n').value = "" + application.tiling.n
    E('entry-m').value = "" + application.tiling.m
    E('grid-num-neighbors').innerHTML = (@tiling.m-2)*@tiling.n
    
  #Actions
  doRandomFill: ->
    randomFillFixedNum @cells, randomFillPercent, unity, randomFillNum, @tiling, randomStateGenerator(@transitionFunc.numStates)
    updatePopulation()
    redraw()

  doStep: (onFinish)->
    #Set generation for thse rules who depend on it
    @transitionFunc.setGeneration @generation
    @cells = evaluateTotalisticAutomaton @cells, @tiling, @transitionFunc.evaluate.bind(@transitionFunc), @transitionFunc.plus, @transitionFunc.plusInitial
    @generation += 1
    redraw()
    updatePopulation()
    updateGeneration()
    onFinish?()
  doReset: ->
    @cells = new ChainMap
    @generation = 0
    @cells.put unity, 1
    updatePopulation()
    updateGeneration()
    redraw()

  doSearch: ->
    found = @navigator.search @cells
    updateCanvasSize()
    if found > 0
      @navigator.navigateToResult 0
      
  importData: (data)->
    try
      console.log "importing #{data}"
      match = data.match /^(\d+)\$(\d+)\$(.*)$/
      throw new Error("Data format unrecognized") unless match?
      n = parseIntChecked match[1]
      m = parseIntChecked match[2]

      if n isnt @tiling.n or m isnt @tiling.m
        console.log "Need to change grid"
        @setGridImpl n, m

      #normzlize chain coordinates, so that importing of user-generated data could be possible
      normalizeChain = (chain) => @tiling.toCell @tiling.rewrite chain
        
      @cells = importField parseFieldData(match[3]), null, normalizeChain
      console.log "Imported #{@cells.count} cells"
    catch e
      alert "Faield to import data: #{e}"
      @cells = new ChainMap

  loadData: (record, cellData) ->
    assert = (x) ->
      throw new Error("Assertion failure") unless x?
      x
    @setGridImpl assert(record.gridN), assert(record.gridM)
    @animator.reset()
    @cells = importField parseFieldData assert(cellData)
    @generation = assert record.generation

    @observer.navigateTo @tiling.parse(assert(record.base)), assert(record.offset)

    console.log "LOading func type= #{record.funcType}"
    switch record.funcType
      when "binary"
        @transitionFunc = parseTransitionFunction record.funcId, record.gridN, record.gridM
        @ruleEntry.setValue @transitionFunc
      when "custom"
        @transitionFunc = new GenericTransitionFunc record.funcId
        @paintStateSelector.update @transitionFunc
      else
        throw new Error "unknown TF type #{record.funcType}"
    
    updatePopulation()
    updateGeneration()
    @updateRuleEditor()
    redraw()
    
  getSaveData: (fname)->
    #[data, catalogRecord]
    fieldData = stringifyFieldData exportField @cells
    funcId = ""+@getTransitionFunc()
    funcType = @getTransitionFunc().getType()
    catalogRecord =
      gridN: @tiling.n
      gridM: @tiling.m
      name: fname
      funcId: funcId
      funcType: funcType
      base: @getObserver().getViewCenter().toString()
      offset: @getObserver().getViewOffsetMatrix()
      size: fieldData.length
      time: Date.now()
      field: null
      generation: @generation
    return [fieldData, catalogRecord]
    
  toggleCellAt: (x,y) ->
    [xp, yp] = @canvas2relative x, y
    try
      cell = @observer.cellFromPoint xp, yp
    catch e
      return
      
    if @cells.get(cell) is @paintStateSelector.state
      @cells.remove cell
    else
      @cells.put cell, @paintStateSelector.state
    redraw()
    
  doExportSvg: ->
    sz = 512
    svgContext = new C2S sz, sz
    drawEverything sz, sz, svgContext
    # Show the generated SVG image
    @svgDialog.show svgContext.getSerializedSvg()

  doExportUrl: ->
    #Export field state as URL
    keys = []
    keys.push "grid=#{@tiling.n},#{@tiling.m}"
    if @cells.count != 0
      keys.push "cells=#{@tiling.n}$#{@tiling.m}$#{stringifyFieldData exportField @cells}"
    keys.push "generation=#{@generation}"
    if @transitionFunc.getType() is "binary"
      ruleStr = ""+@transitionFunc
      ruleStr = ruleStr.replace /\s/g, '_'
      keys.push "rule=#{ruleStr}"
    keys.push "viewbase=#{@getObserver().getViewCenter()}"
    [rot, dx, dy] = M.hyperbolicDecompose @getObserver().getViewOffsetMatrix()
    
    keys.push "viewoffset=#{rot}:#{dx}:#{dy}"

    basePath = location.href.replace(location.search, '')
    uri = basePath + "?" + keys.join("&")
    showExportDialog uri
    
class SvgDialog
  constructor: (@application) ->
    @dialog = E('svg-export-dialog')
    @imgContainer = E('svg-image-container')
    
  close: ->
    @imgContainer.innerHTML = ""
    @dialog.style.display="none"
    
  show: (svg) ->
    dataUri = "data:image/svg+xml;utf8," + encodeURIComponent(svg)
    dom = new DomBuilder()
    dom.tag('img').a('src', dataUri).a('alt', 'SVG image').a('title', 'Use right click to save SVG image').end()    
    @imgContainer.innerHTML = ""
    @imgContainer.appendChild dom.finalize()
    #@imgContainer.innerHTML = svg
    @dialog.style.display=""
    

updateCanvasSize = ->
  return if canvasSizeUpdateBlocked
  
  docW = documentWidth()
  winW = windowWidth()
  
  if docW > winW
    console.log "overflow"
    usedWidth = docW - canvas.width
    #console.log "#Win: #{windowWidth()}, doc: #{documentWidth()}, used: #{usedWidth}"
    w = winW - usedWidth
  else
    #console.log "underflow"
    containerAvail=E('canvas-container').clientWidth
    #console.log "awail width: #{containerAvail}"
    w = containerAvail

  #now calculae available height
  canvasRect = canvas.getBoundingClientRect()
  winH = windowHeight()
  h = winH - canvasRect.top

  navWrap = E('navigator-wrap')
  navWrap.style.height = "#{winH - navWrap.getBoundingClientRect().top - 16}px"

  #get the smaller of both
  w = Math.min(w,h) 
  #reduce it a bit
  w -= 16
  
  #make width multiple of 16
  w = w & ~ 15
  
  #console.log "New w is #{w}"
  if w <= MIN_WIDTH
    w = MIN_WIDTH

  if canvas.width isnt w
    canvas.width = canvas.height = w
    redraw()
    E('image-size').value = ""+w
  return

doSetFixedSize = (isFixed) ->
  if isFixed
    size = parseIntChecked E('image-size').value
    if size <= 0 or size >=65536
      throw new Error "Bad size: #{size}"
    canvasSizeUpdateBlocked = true
    canvas.width = canvas.height = size
    redraw()
  else
    canvasSizeUpdateBlocked = false
    updateCanvasSize()

class PaintStateSelector
  constructor: (@application, @container, @buttonContainer)->
    @state = 1
    @numStates = 2
    
  update: ->
    numStates = @application.getTransitionFunc().numStates
    #only do something if number of states changed
    return if numStates == @numStates
    @numStates = numStates
    console.log "Num states changed to #{numStates}"
    if @state >= numStates
      @state = 1
    @buttonContainer.innerHTML = ''
    if numStates <= 2
      @container.style.display = 'none'
      @buttons = null
      @state2id = null
    else
      @container.style.display = ''
      dom = new DomBuilder()
      id2state = {}
      @state2id = {}
      for state in [1...numStates]
        color = @application.observer.getColorForState state
        btnId = "select-state-#{state}"
        @state2id[state] = btnId
        id2state[btnId] = state
        dom.tag('button').store('btn')\
           .CLASS(if state is @state then 'btn-selected' else '')\
           .ID(btnId)\
           .a('style', "background-color:#{color}")\
           .text(''+state)\
           .end()
        #dom.vars.btn.onclick = (e)->
      @buttonContainer.appendChild dom.finalize()
      @buttons = new ButtonGroup @buttonContainer, 'button'
      @buttons.addEventListener 'change', (e, btnId, oldBtn)=>
        if (state = id2state[btnId])?
          @state = state
  setState: (newState) ->
    return if newState is @state
    return unless @state2id[newState]?
    @state = newState
    if @buttons
      @buttons.setButton @state2id[newState]

serverSupportsUpload = -> ((""+window.location).match /:8000\//) and true
# ============================================  app code ===============
#
if serverSupportsUpload()
  console.log "Enable upload"
  E('animate-controls').style.display=''

canvas = E "canvas"
context = canvas.getContext "2d"


dragHandler = null
ghostClickDetector = new GhostClickDetector

player = null
playerTimeout = 500
autoplayCriticalPopulation = 90000
doStartPlayer = ->
  return if player?

  runPlayerStep = ->
    if application.cells.count >= autoplayCriticalPopulation
      alert "Population reached #{application.cells.count}, stopping auto-play"
      player = null
    else
      player = setTimeout( (-> application.doStep(runPlayerStep)), playerTimeout )
    updatePlayButtons()

  runPlayerStep()
  
doStopPlayer = ->
  if player
    clearTimeout player
    player = null
    updatePlayButtons()

doTogglePlayer = ->
  if player
    doStopPlayer()
  else
    doStartPlayer()

updateGenericRuleStatus = (status)->
  span = E 'generic-tf-status'
  span.innerHTML = status
  span.setAttribute('class', 'generic-tf-status-#{status.toLowerCase()}')  
      
updatePlayButtons = ->
  E('btn-play-start').style.display = if player then "none" else ''
  E('btn-play-stop').style.display = unless player then "none" else ''

dirty = true
redraw = -> dirty = true

drawEverything = (w, h, context) ->
  return false unless application.observer.canDraw()
  context.fillStyle = "white"
  #context.clearRect 0, 0, canvas.width, canvas.height
  context.fillRect 0, 0, w, h
  context.save()
  s = Math.min( w, h ) / 2 #
  s1 = s-application.getMargin()
  context.translate s, s
  application.observer.draw application.cells, context, s1
  context.restore()
  return true

fpsLimiting = true
lastTime = Date.now()
fpsDefault = 30
dtMax = 1000.0/fpsDefault #

redrawLoop = ->
  if dirty
    if not fpsLimiting or ((t=Date.now()) - lastTime > dtMax)
      if drawEverything canvas.width, canvas.height, context
        tDraw = Date.now() - t
        #adaptively update FPS
        dtMax = dtMax*0.9 + tDraw*2*0.1
        dirty = false
      lastTime = t
  requestAnimationFrame redrawLoop
    


isPanMode = true
doCanvasMouseDown = (e) ->
  #Allow normal right-click to support image sacing
  E('canvas-container').focus()
  return if e.button is 2
  #Only in mozilla?
  canvas.setCapture? true
  
  e.preventDefault()
  [x,y] = getCanvasCursorPosition e, canvas

  isPanAction = (e.button is 1) ^ (e.shiftKey) ^ (isPanMode)
  unless isPanAction
    application.toggleCellAt x, y
    updatePopulation()    
  else
    dragHandler = new MouseToolCombo application, x, y

doCanvasMouseUp = (e) ->
  e.preventDefault()
  if dragHandler isnt null
    dragHandler?.mouseUp e
    dragHandler = null

doCanvasTouchStart = (e)->
  if e.touches.length is 1 
    doCanvasMouseDown(e)
    e.preventDefault()
      
doCanvasTouchLeave = (e)->
  doCanvasMouseOut(e)
    
doCanvasTouchEnd = (e)->
  e.preventDefault()
  doCanvasMouseUp(e)
      
doCanvasTouchMove = (e)->
  doCanvasMouseMove(e)
    


doSetPanMode = (mode) ->
  isPanMode = mode

  bpan = E('btn-mode-pan')
  bedit = E('btn-mode-edit')
  removeClass bpan, 'button-active'
  removeClass bedit, 'button-active'

  addClass (if isPanMode then bpan else bedit), 'button-active'
  
doCanvasMouseMove = (e) ->
  
  isPanAction = (e.shiftKey) ^ (isPanMode)
  E('canvas-container').style.cursor = if isPanAction then 'move' else 'default'
    
  if dragHandler isnt null
    e.preventDefault()
    dragHandler.mouseMoved e


doOpenEditor = ->
  E('generic-tf-code').value = application.transitionFunc.code  
  E('generic-tf-editor').style.display = ''

doCloseEditor = ->
  E('generic-tf-editor').style.display = 'none'

doSetRuleGeneric = ->
  try
    console.log "Set generic rule"
    application.transitionFunc = new GenericTransitionFunc E('generic-tf-code').value
    updateGenericRuleStatus 'Compiled'
    application.paintStateSelector.update application.transitionFunc
    application.updateRuleEditor()
    E('controls-rule-simple').style.display="none"
    E('controls-rule-generic').style.display=""
    true
  catch e
    alert "Failed to parse function: #{e}"
    updateGenericRuleStatus 'Error'
    false

doSetGrid = ->
  try
    n = parseInt E('entry-n').value, 10
    m = parseInt E('entry-m').value, 10
    if Number.isNaN(n) or n <= 0
      throw new Error "Parameter N is bad"

    if Number.isNaN(m) or m <= 0
      throw new Error "Parameter M is bad"
    #if 1/n + 1/m <= 1/2
    if 2*(n+m) >= n*m
      throw new Error "Tessellation {#{n}; #{m}} is not hyperbolic and not supported."
  catch e
    alert ""+e
    return
  application.setGridImpl n, m
  application.doReset()
  application.animator.reset()
    

updatePopulation = ->
  E('population').innerHTML = ""+application.cells.count
updateGeneration = ->
  E('generation').innerHTML = ""+application.generation    

#exportTrivial = (cells) ->
#  parts = []
#  cells.forItems (cell, value)->
#    parts.push ""+cell
#    parts.push ""+value
#  return parts.join " "
  
doExport = ->
  data = stringifyFieldData exportField application.cells
  n = application.tiling.n
  m = application.tiling.m
  showExportDialog "#{n}$#{m}$#{data}"

doExportClose = ->
  E('export-dialog').style.display = 'none'

uploadToServer = (imgname, callback)->
  dataURL = canvas.toDataURL();  
  cb = (blob) ->
    formData = new FormData()
    formData.append "file", blob, imgname
    ajax = getAjax()
    ajax.open 'POST', '/uploads/', false
    ajax.onreadystatechange = -> callback(ajax)
    ajax.send(formData)
  canvas.toBlob cb, "image/png"

memo = null
doMemorize = ->
  memo =
    cells: application.cells.copy()
    viewCenter: application.observer.getViewCenter()
    viewOffset: application.observer.getViewOffsetMatrix()
    generation: application.generation
  console.log "Position memoized"
  updateMemoryButtons()
  
doRemember = ->
  if memo is null
    console.log "nothing to remember"
  else
    application.cells = memo.cells.copy()
    application.generation = memo.generation
    application.observer.navigateTo memo.viewCenter, memo.viewOffset
    updatePopulation()
    updateGeneration()

doClearMemory = ->
  memo = null        
  updateMemoryButtons()
  
updateMemoryButtons = ->
  E('btn-mem-get').disabled = E('btn-mem-clear').disabled = memo is null

encodeVisible = ->
  iCenter = application.tiling.inverse application.observer.cellFromPoint(0,0)
  visibleCells = new ChainMap
  for [cell, state] in application.observer.visibleCells application.cells
    translatedCell = application.tiling.append iCenter, cell
    translatedCell = application.tiling.toCell translatedCell
    visibleCells.put translatedCell, state
  return exportField visibleCells

showExportDialog = (sdata) ->
  E('export').value = sdata
  E('export-dialog').style.display = ''
  E('export').focus()
  E('export').select()
  
doExportVisible = ->
  n = application.tiling.n
  m = application.tiling.m
  data = stringifyFieldData encodeVisible()
  showExportDialog "#{n}$#{m}$#{data}"
  
doShowImport = ->
  E('import-dialog').style.display = ''
  E('import').focus()
  
doImportCancel = ->
  E('import-dialog').style.display = 'none'
  E('import').value=''
  
doImport = ->
  try
    application.importData E('import').value
    updatePopulation()
    redraw()
    E('import-dialog').style.display = 'none'
    E('import').value=''
  catch e
    alert "Error parsing: #{e}"
    
doEditAsGeneric = ->
  application.transitionFunc = application.transitionFunc.toGeneric()
  updateGenericRuleStatus 'Compiled'
  application.paintStateSelector.update application.transitionFunc
  application.updateRuleEditor()
  doOpenEditor()

doDisableGeneric = ->
  application.doSetRule()

doNavigateHome = ->
  application.observer.navigateTo unity

# ============ Bind Events =================
E("btn-reset").addEventListener "click", ->application.doReset()
E("btn-step").addEventListener "click", ->application.doStep()
mouseMoveReceiver = E("canvas-container")
mouseMoveReceiver.addEventListener "mousedown", (e) -> doCanvasMouseDown(e) unless ghostClickDetector.isGhost
mouseMoveReceiver.addEventListener "mouseup", (e) -> doCanvasMouseUp(e) unless ghostClickDetector.isGhost
mouseMoveReceiver.addEventListener "mousemove", doCanvasMouseMove
mouseMoveReceiver.addEventListener "mousedrag", doCanvasMouseMove

mouseMoveReceiver.addEventListener "touchstart", doCanvasTouchStart
mouseMoveReceiver.addEventListener "touchend", doCanvasTouchEnd
mouseMoveReceiver.addEventListener "touchmove", doCanvasTouchMove
mouseMoveReceiver.addEventListener "touchleave", doCanvasTouchLeave

ghostClickDetector.addListeners canvas


E("btn-set-rule").addEventListener "click", (e)->application.doSetRule()
E("btn-set-rule-generic").addEventListener "click", (e)->
  doSetRuleGeneric()
  doCloseEditor()
E("btn-rule-generic-close-editor").addEventListener "click", doCloseEditor
E("btn-set-grid").addEventListener "click", doSetGrid

E("btn-export").addEventListener "click", doExport
E('btn-search').addEventListener 'click', ->application.doSearch()
E('btn-random').addEventListener 'click', -> application.doRandomFill()
E('btn-rule-make-generic').addEventListener 'click', doEditAsGeneric
E('btn-edit-rule').addEventListener 'click', doOpenEditor
E('btn-disable-generic-rule').addEventListener 'click', doDisableGeneric
E('btn-export-close').addEventListener 'click', doExportClose
E('btn-import').addEventListener 'click', doShowImport
E('btn-import-cancel').addEventListener 'click', doImportCancel
E('btn-import-run').addEventListener 'click', doImport
#initialize
E('btn-mem-set').addEventListener 'click', doMemorize
E('btn-mem-get').addEventListener 'click', doRemember
E('btn-mem-clear').addEventListener 'click', doClearMemory
E('btn-exp-visible').addEventListener 'click', doExportVisible
E('btn-nav-home').addEventListener 'click', doNavigateHome
window.addEventListener 'resize', updateCanvasSize
E('btn-nav-clear').addEventListener 'click', (e) -> application.navigator.clear()
E('btn-play-start').addEventListener 'click', doTogglePlayer
E('btn-play-stop').addEventListener 'click', doTogglePlayer

E('animate-set-start').addEventListener 'click', -> application.animator.setStart application.observer
E('animate-set-end').addEventListener 'click', -> application.animator.setEnd application.observer

E('animate-view-start').addEventListener 'click', -> application.animator.viewStart application.observer
E('animate-view-end').addEventListener 'click', -> application.animator.viewEnd application.observer
E('btn-animate-derotate').addEventListener 'click', -> application.animator.derotate()

E('btn-upload-animation').addEventListener 'click', (e)->
  application.animator.animate application.observer, parseIntChecked(E('animate-frame-per-generation').value), parseIntChecked(E('animate-generations').value), (-> null)
E('btn-animate-cancel').addEventListener 'click', (e)->application.animator.cancelWork()

E('view-straighten').addEventListener 'click', (e)-> application.observer.straightenView()

E('view-straighten').addEventListener 'click', (e)-> application.observer.straightenView()
E('image-fix-size').addEventListener 'click', (e)-> doSetFixedSize E('image-fix-size').checked
E('image-size').addEventListener 'change', (e) ->
  E('image-fix-size').checked=true
  doSetFixedSize true
  
E('flag-origin-mark').addEventListener 'change', (e)->
  application.setDrawingHomePtr E('flag-origin-mark').checked
E('flag-live-borders').addEventListener 'change', (e)->
  application.setShowLiveBorders E('flag-live-borders').checked
  
E('btn-mode-edit').addEventListener 'click', (e) -> doSetPanMode false
E('btn-mode-pan').addEventListener 'click', (e) -> doSetPanMode true
E('btn-db-save').addEventListener 'click', (e) -> application.saveDialog.show()
E('btn-db-load').addEventListener 'click', (e) -> application.openDialog.show()
E('btn-export-svg').addEventListener 'click', (e) -> application.doExportSvg()
E('btn-svg-export-dialog-close').addEventListener 'click', (e) -> application.svgDialog.close()
E('btn-export-uri').addEventListener 'click', (e) -> application.doExportUrl()

shortcuts =
  'N': -> application.doStep()
  'C': -> application.doReset()
  'S': -> application.doSearch()
  'R': ->application.doRandomFill()
  '1': (e) -> application.paintStateSelector.setState 1
  '2': (e) -> application.paintStateSelector.setState 2
  '3': (e) -> application.paintStateSelector.setState 3
  '4': (e) -> application.paintStateSelector.setState 4
  '5': (e) -> application.paintStateSelector.setState 5
  'M': doMemorize
  'U': doRemember
  'UA': doClearMemory
  'H': doNavigateHome
  'G': doTogglePlayer
  'SA': (e) -> application.observer.straightenView()
  '#32': doTogglePlayer
  'P': (e) -> doSetPanMode true
  'E': (e) -> doSetPanMode false
  'SC': (e) -> application.saveDialog.show()
  'OC': (e) -> application.openDialog.show()
  
document.addEventListener "keydown", (e)->
  focused = document.activeElement
  if focused and focused.tagName.toLowerCase() in ['textarea', 'input']
    return
  keyCode = if e.keyCode > 32 and e.keyCode < 128
    String.fromCharCode e.keyCode
  else
    '#' + e.keyCode
  keyCode += "C" if e.ctrlKey
  keyCode += "A" if e.altKey
  keyCode += "S" if e.shiftKey
  #console.log keyCode
  if (handler = shortcuts[keyCode])?
    e.preventDefault()
    handler(e)

##Application startup    
application = new Application
application.initialize new UriConfig

doSetPanMode true
updatePopulation()
updateGeneration()
updateCanvasSize()
updateMemoryButtons()
updatePlayButtons()
redrawLoop()

#application.saveDialog.show()
