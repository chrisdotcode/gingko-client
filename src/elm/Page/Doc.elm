module Page.Doc exposing (Model, Msg, MsgToParent(..), exitFullscreenExposed, getActiveId, getActiveTree, getField, getGlobalData, getTextCursorInfo, getViewMode, getWorkingTree, init, isDirty, isFullscreen, isNormalMode, lastActives, opaqueIncoming, opaqueUpdate, openCardFullscreenMsg, saveAndStopEditing, saveCardIfEditing, setBlock, setDirty, setGlobalData, setLoading, setTree, setWorkingTree, subscriptions, updateField, view)

import Ant.Icons.Svg as AntIcons
import Browser.Dom exposing (Element)
import Coders exposing (treeToValue)
import Doc.Fonts as Fonts
import Doc.TreeStructure as TreeStructure exposing (defaultTree)
import Doc.TreeUtils exposing (..)
import Doc.UI as UI exposing (viewMobileButtons, viewSearchField)
import GlobalData exposing (GlobalData)
import Html exposing (Attribute, Html, div, span, text, textarea)
import Html.Attributes as Attributes exposing (attribute, class, classList, dir, id, style, title, value)
import Html.Events exposing (custom, onClick, onDoubleClick, onInput)
import Html.Extra exposing (viewIf)
import Html.Keyed as Keyed
import Html.Lazy exposing (lazy2, lazy4, lazy5, lazy7, lazy8)
import Html5.DragDrop as DragDrop
import Json.Decode as Json
import List.Extra as ListExtra
import Markdown
import Outgoing exposing (Msg(..), send)
import Page.Doc.Incoming as Incoming exposing (Msg(..))
import Random
import Regex
import Task
import Time
import Translation exposing (Language, TranslationId(..), tr)
import Types exposing (..)
import Utils exposing (randomPositiveInt)



-- MODEL


type alias ModelData =
    -- Document state
    { workingTree : TreeStructure.Model

    -- SPA Page State
    , globalData : GlobalData
    , loading : Bool
    , block : Maybe String

    -- Transient state
    , viewState : ViewState
    , dirty : Bool
    , textCursorInfo : TextCursorInfo
    , fileSearchField : String

    -- Settings
    , uid : String
    , fonts : Fonts.Model
    }


type Model
    = Model ModelData


init : Bool -> GlobalData -> Model
init isNew globalData =
    Model
        { workingTree = TreeStructure.defaultModel
        , globalData = globalData
        , loading = not isNew
        , block = Nothing
        , uid = "0"
        , viewState =
            { viewMode =
                if isNew then
                    Editing { cardId = "1", field = "" }

                else
                    Normal ""
            , activePast = []
            , descendants = []
            , ancestors = [ "0" ]
            , searchField = Nothing
            , dragModel = ( DragDrop.init, DragExternalModel Nothing False )
            , draggedTree = Nothing
            , copiedTree = Nothing
            , clipboardTree = Nothing
            , collaborators = []
            }
        , dirty = False
        , textCursorInfo = { selected = False, position = End, text = ( "", "" ) }
        , fileSearchField = ""
        , fonts = Fonts.default
        }



-- UPDATE


type Msg
    = NoOp
      -- === Card Activation ===
    | Activate String
    | SearchFieldUpdated String
      -- === Card Editing  ===
    | OpenCard String String
    | UpdateEditingField String String
    | AutoSave
    | SaveAndCloseCard
    | EditToFullscreenMode
    | DeleteCard String
      -- === Card Insertion  ===
    | InsertAbove String
    | InsertBelow String
    | InsertChild String
      -- === Dragging ===
    | DragDropMsg (DragDrop.Msg String DropId)
    | DragExternal DragExternalMsg
      -- === UI ===
      -- Misc UI
    | FullscreenRequested
      -- === Ports ===
    | LogErr String


type MsgToParent
    = CloseTooltip
    | LocalSave CardTreeOp
    | Commit
    | ExitFullscreen


type DragExternalMsg
    = DragEnter DropId
    | DragLeave DropId


opaqueUpdate : Msg -> Model -> ( Model, Cmd Msg, List MsgToParent )
opaqueUpdate msg (Model model) =
    let
        ( newModel, cmd, pMsgs ) =
            update msg model
    in
    ( Model newModel, cmd, pMsgs )


update : Msg -> ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
update msg ({ workingTree } as model) =
    let
        vs =
            model.viewState
    in
    case msg of
        -- === Card Activation ===
        Activate id ->
            ( model
            , Cmd.none
            , []
            )
                |> saveCardIfEditing
                |> activate id False

        SearchFieldUpdated inputField ->
            let
                searchFilter term_ cols =
                    case term_ of
                        Just term ->
                            let
                                hasTerm tree =
                                    term
                                        |> Regex.fromStringWith { caseInsensitive = True, multiline = False }
                                        |> Maybe.withDefault Regex.never
                                        |> (\t -> Regex.contains t tree.content)
                            in
                            cols
                                |> List.map (\c -> List.map (\g -> List.filter hasTerm g) c)

                        Nothing ->
                            cols

                ( maybeBlur, newSearchField ) =
                    case inputField of
                        "" ->
                            ( \( m, c, p ) ->
                                ( m
                                , Cmd.batch [ c, Task.attempt (\_ -> NoOp) (Browser.Dom.blur "search-input") ]
                                , p
                                )
                            , Nothing
                            )

                        str ->
                            ( identity
                            , Just str
                            )

                filteredCardIds =
                    searchFilter newSearchField model.workingTree.columns
                        |> List.map (\c -> List.map (\g -> List.map .id g) c)
                        |> List.concat
                        |> List.concat

                allCardsInOrder =
                    getDescendants model.workingTree.tree
                        |> List.map .id

                firstFilteredCardId_ =
                    ListExtra.find (\cId -> List.member cId filteredCardIds) allCardsInOrder

                maybeActivate =
                    case ( newSearchField, firstFilteredCardId_ ) of
                        ( Just _, Just id ) ->
                            activate id False

                        ( Nothing, _ ) ->
                            activate (getActiveId (Model model)) False

                        _ ->
                            identity
            in
            ( { model | viewState = { vs | searchField = newSearchField } }
            , Cmd.none
            , []
            )
                |> maybeBlur
                |> maybeActivate

        -- === Card Editing  ===
        OpenCard id str ->
            model
                |> openCard id str

        UpdateEditingField id newField ->
            case vs.viewMode of
                Editing { cardId, field } ->
                    if id == cardId && field /= newField then
                        ( { model
                            | viewState = { vs | viewMode = Editing { cardId = id, field = newField } }
                            , dirty = True
                          }
                        , Cmd.batch
                            [ send <| SetDirty True
                            , send <| SetTextareaClone cardId newField
                            ]
                        , []
                        )

                    else
                        ( model
                        , Cmd.none
                        , []
                        )

                _ ->
                    ( model
                    , Cmd.none
                    , []
                    )

        AutoSave ->
            ( model, Cmd.none, [] ) |> saveCardIfEditing

        SaveAndCloseCard ->
            saveAndStopEditing model

        EditToFullscreenMode ->
            model |> enterFullscreen

        DeleteCard id ->
            ( model
            , Cmd.none
            , []
            )
                |> deleteCard id

        -- === Card Insertion  ===
        InsertAbove id ->
            ( model
            , Cmd.none
            , []
            )
                |> insertAbove id ""

        InsertBelow id ->
            ( model
            , Cmd.none
            , []
            )
                |> insertBelow id ""

        InsertChild id ->
            ( model
            , Cmd.none
            , []
            )
                |> insertChild id ""

        -- === Card Moving  ===
        DragDropMsg dragDropMsg ->
            let
                ( newDragModel, dragResult_ ) =
                    DragDrop.update dragDropMsg (Tuple.first vs.dragModel)

                modelDragUpdated =
                    { model
                        | viewState =
                            { vs
                                | dragModel = ( newDragModel, Tuple.second vs.dragModel )
                            }
                    }
            in
            case ( DragDrop.getDragId newDragModel, dragResult_ ) of
                ( Just _, Nothing ) ->
                    -- Dragging
                    ( modelDragUpdated
                    , DragDrop.getDragstartEvent dragDropMsg
                        |> Maybe.map .event
                        |> Maybe.map (\json -> send <| DragStart json)
                        |> Maybe.withDefault Cmd.none
                    , []
                    )
                        |> preventIfBlocked model

                ( Nothing, Just ( _, dropId, _ ) ) ->
                    -- Drop success
                    case vs.draggedTree of
                        Just ( draggedTree, _, _ ) ->
                            let
                                moveOperation =
                                    case dropId of
                                        Into id ->
                                            move draggedTree id 999999

                                        Above id ->
                                            move draggedTree
                                                ((getParent id model.workingTree.tree |> Maybe.map .id) |> Maybe.withDefault "0")
                                                ((getIndex id model.workingTree.tree |> Maybe.withDefault 0) |> Basics.max 0)

                                        Below id ->
                                            move draggedTree
                                                ((getParent id model.workingTree.tree |> Maybe.map .id) |> Maybe.withDefault "0")
                                                ((getIndex id model.workingTree.tree |> Maybe.withDefault 0) + 1)
                            in
                            ( { modelDragUpdated | viewState = { vs | draggedTree = Nothing }, dirty = True }, Cmd.batch [ send <| SetDirty True, send <| DragDone ], [] )
                                |> moveOperation

                        Nothing ->
                            ( modelDragUpdated, Cmd.none, [] )

                ( Nothing, Nothing ) ->
                    -- NotDragging
                    case vs.draggedTree of
                        Just ( draggedTree, parentId, idx ) ->
                            ( modelDragUpdated, Cmd.none, [] )
                                |> move draggedTree parentId idx

                        Nothing ->
                            ( modelDragUpdated, Cmd.none, [] )

                ( Just _, Just _ ) ->
                    -- Should be Impossible: both Dragging and Dropped
                    ( modelDragUpdated, Cmd.none, [] )

        DragExternal dragExternalMsg ->
            case dragExternalMsg of
                DragEnter dId ->
                    ( { model | viewState = { vs | dragModel = ( Tuple.first vs.dragModel, { dropId = Just dId, isDragging = True } ) } }, Cmd.none, [] )

                DragLeave dId ->
                    if (Tuple.second vs.dragModel |> .dropId) == Just dId then
                        ( { model | viewState = { vs | dragModel = ( Tuple.first vs.dragModel, { dropId = Nothing, isDragging = True } ) } }, Cmd.none, [] )

                    else
                        ( model, Cmd.none, [] )

        -- === UI ===
        FullscreenRequested ->
            ( model, send <| RequestFullscreen, [] )

        -- === Ports ===
        LogErr _ ->
            ( model, Cmd.none, [] )

        NoOp ->
            ( model
            , Cmd.none
            , []
            )


localSave : CardTreeOp -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
localSave op ( model, cmd, prevMsgsToParent ) =
    ( model
    , cmd
    , prevMsgsToParent ++ [ LocalSave op ]
    )


addToHistory : ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
addToHistory ( model, cmd, prevMsgsToParent ) =
    ( model
    , cmd
    , prevMsgsToParent ++ [ Commit ]
    )


opaqueIncoming : Incoming.Msg -> Model -> ( Model, Cmd Msg, List MsgToParent )
opaqueIncoming msg (Model model) =
    let
        ( newModel, cmd, msgsToParent ) =
            incoming msg model
    in
    ( Model newModel, cmd, msgsToParent )


incoming : Incoming.Msg -> ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
incoming incomingMsg model =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    case incomingMsg of
        -- === Dialogs, Menus, Window State ===
        CancelCardConfirmed ->
            ( { model | dirty = False }
            , send <| SetDirty False
            , []
            )
                |> cancelCard

        -- === DOM ===
        InitialActivation ->
            case vs.viewMode of
                Normal "" ->
                    ( model, Cmd.none, [] )
                        |> activate "" False

                _ ->
                    ( model, Cmd.none, [] )

        DragStarted dragId ->
            let
                newTree =
                    TreeStructure.update (TreeStructure.Rmv dragId) model.workingTree

                draggedTree =
                    getTreeWithPosition dragId model.workingTree.tree
            in
            if List.isEmpty <| getChildren newTree.tree then
                ( model, Cmd.none, [] )

            else
                ( { model | workingTree = newTree, viewState = { vs | draggedTree = draggedTree } }, Cmd.none, [] )

        DragExternalStarted ->
            case vs.viewMode of
                Normal _ ->
                    ( { model
                        | viewState =
                            { vs
                                | dragModel =
                                    ( Tuple.first vs.dragModel
                                    , { dropId = Nothing, isDragging = True }
                                    )
                            }
                      }
                    , Cmd.none
                    , []
                    )

                _ ->
                    ( model, Cmd.none, [] )

        DropExternal dropText ->
            case Tuple.second vs.dragModel |> .dropId of
                Just dropId ->
                    let
                        modelNoDrag =
                            { model | viewState = { vs | dragModel = ( Tuple.first vs.dragModel, { dropId = Nothing, isDragging = False } ) } }

                        baseModelCmdTuple =
                            case dropId of
                                Above cardId ->
                                    ( modelNoDrag, Cmd.none, [] ) |> insertAbove cardId dropText

                                Into cardId ->
                                    ( modelNoDrag, Cmd.none, [] ) |> insertChild cardId dropText

                                Below cardId ->
                                    ( modelNoDrag, Cmd.none, [] ) |> insertBelow cardId dropText
                    in
                    baseModelCmdTuple
                        |> closeCard
                        |> addToHistory

                Nothing ->
                    ( model, Cmd.none, [] )

        FullscreenChanged fullscreen ->
            case vs.viewMode of
                FullscreenEditing _ ->
                    if not fullscreen then
                        exitFullscreen model

                    else
                        ( model, Cmd.none, [] )

                _ ->
                    ( model, Cmd.none, [] )

        Paste tree ->
            normalMode model (pasteBelow activeId tree)

        PasteInto tree ->
            normalMode model (pasteInto activeId tree)

        FieldChanged str ->
            case vs.viewMode of
                Editing { cardId } ->
                    ( { model
                        | viewState = { vs | viewMode = Editing { cardId = cardId, field = str } }
                        , dirty = True
                      }
                    , Cmd.none
                    , []
                    )

                _ ->
                    ( model, Cmd.none, [] )

        TextCursor textCursorInfo ->
            if model.textCursorInfo /= textCursorInfo then
                ( { model | textCursorInfo = textCursorInfo }
                , Cmd.none
                , []
                )

            else
                ( model, Cmd.none, [] )

        ClickedOutsideCard ->
            case model.viewState.viewMode of
                Editing _ ->
                    ( model, Cmd.none, [] )
                        |> closeCard

                _ ->
                    ( model, Cmd.none, [] )

        CheckboxClicked cardId checkboxNumber ->
            case getTree cardId model.workingTree.tree of
                Nothing ->
                    ( model, Cmd.none, [] )

                Just originalCard ->
                    let
                        checkboxes =
                            Regex.fromStringWith { caseInsensitive = True, multiline = True }
                                "\\[(x| )\\]"
                                |> Maybe.withDefault Regex.never

                        checkboxReplacer { match, number } =
                            case ( number == checkboxNumber, match ) of
                                ( True, "[ ]" ) ->
                                    "[X]"

                                ( True, "[x]" ) ->
                                    "[ ]"

                                ( True, "[X]" ) ->
                                    "[ ]"

                                _ ->
                                    match

                        newContent =
                            originalCard.content
                                |> Regex.replace checkboxes checkboxReplacer

                        newTree =
                            TreeStructure.update (TreeStructure.Upd cardId newContent) model.workingTree
                    in
                    ( { model | workingTree = newTree, dirty = True }, Cmd.none, [] )
                        |> localSave (CTUpd cardId newContent)
                        |> addToHistory

        -- === UI ===
        Keyboard shortcut ->
            case shortcut of
                "shift+enter" ->
                    case vs.viewMode of
                        Normal active ->
                            ( model
                            , Cmd.none
                            , []
                            )
                                |> openCardFullscreen active (getContent active model.workingTree.tree)
                                |> preventIfBlocked model

                        _ ->
                            ( model, Cmd.none, [] )

                "mod+enter" ->
                    saveAndStopEditing model

                "mod+s" ->
                    saveCardIfEditing ( model, Cmd.none, [] )

                "enter" ->
                    normalMode model (andThen <| openCard activeId (getContent activeId model.workingTree.tree))

                "mod+backspace" ->
                    normalMode model (deleteCard activeId)

                "esc" ->
                    model |> intentCancelCard

                "mod+j" ->
                    case vs.viewMode of
                        Normal active ->
                            insertBelow active "" ( model, Cmd.none, [] )

                        Editing { cardId } ->
                            let
                                ( beforeText, afterText ) =
                                    model.textCursorInfo.text
                            in
                            ( { model
                                | viewState =
                                    { vs | viewMode = Editing { cardId = cardId, field = beforeText } }
                              }
                            , Cmd.none
                            , []
                            )
                                |> saveCardIfEditing
                                |> insertBelow activeId afterText
                                |> setCursorPosition 0

                        FullscreenEditing { cardId } ->
                            let
                                ( beforeText, afterText ) =
                                    model.textCursorInfo.text
                            in
                            ( { model
                                | viewState =
                                    { vs | viewMode = FullscreenEditing { cardId = cardId, field = beforeText } }
                              }
                            , Cmd.none
                            , []
                            )
                                |> saveCardIfEditing
                                |> insertBelow activeId afterText
                                |> setCursorPosition 0

                "mod+down" ->
                    normalMode model (insertBelow activeId "")

                "mod+k" ->
                    case vs.viewMode of
                        Normal active ->
                            insertAbove active "" ( model, Cmd.none, [] )

                        Editing { cardId } ->
                            let
                                ( beforeText, afterText ) =
                                    model.textCursorInfo.text
                            in
                            ( { model
                                | viewState =
                                    { vs | viewMode = Editing { cardId = cardId, field = afterText } }
                              }
                            , Cmd.none
                            , []
                            )
                                |> saveCardIfEditing
                                |> insertBelow activeId beforeText

                        FullscreenEditing { cardId } ->
                            let
                                ( beforeText, afterText ) =
                                    model.textCursorInfo.text
                            in
                            ( { model
                                | viewState =
                                    { vs | viewMode = FullscreenEditing { cardId = cardId, field = afterText } }
                              }
                            , Cmd.none
                            , []
                            )
                                |> saveCardIfEditing
                                |> insertBelow activeId beforeText

                "mod+up" ->
                    normalMode model (insertAbove activeId "")

                "mod+l" ->
                    case vs.viewMode of
                        Normal active ->
                            insertChild active "" ( model, Cmd.none, [] )

                        Editing { cardId } ->
                            let
                                ( beforeText, afterText ) =
                                    model.textCursorInfo.text
                            in
                            ( { model
                                | viewState =
                                    { vs | viewMode = Editing { cardId = cardId, field = beforeText } }
                              }
                            , Cmd.none
                            , []
                            )
                                |> saveCardIfEditing
                                |> insertChild activeId afterText
                                |> setCursorPosition 0

                        FullscreenEditing { cardId } ->
                            let
                                ( beforeText, afterText ) =
                                    model.textCursorInfo.text
                            in
                            ( { model
                                | viewState =
                                    { vs | viewMode = FullscreenEditing { cardId = cardId, field = beforeText } }
                              }
                            , Cmd.none
                            , []
                            )
                                |> saveCardIfEditing
                                |> insertChild activeId afterText
                                |> setCursorPosition 0

                "mod+right" ->
                    normalMode model (insertChild activeId "")

                "mod+shift+j" ->
                    normalMode model (mergeDown activeId)

                "mod+shift+down" ->
                    normalMode model (mergeDown activeId)

                "mod+shift+k" ->
                    normalMode model (mergeUp activeId)

                "mod+shift+up" ->
                    normalMode model (mergeUp activeId)

                "h" ->
                    normalMode model (goLeft activeId)

                "left" ->
                    normalMode model (goLeft activeId)

                "j" ->
                    normalMode model (goDown activeId)

                "down" ->
                    case vs.viewMode of
                        Normal active ->
                            ( model, Cmd.none, [] )
                                |> goDown active

                        FullscreenEditing _ ->
                            {- check if at end
                               if so, getNextInColumn and openCardFullscreen it
                            -}
                            ( model, Cmd.none, [] )

                        Editing _ ->
                            ( model, Cmd.none, [] )

                "k" ->
                    normalMode model (goUp activeId)

                "up" ->
                    normalMode model (goUp activeId)

                "l" ->
                    normalMode model (goRight activeId)

                "right" ->
                    normalMode model (goRight activeId)

                "alt+up" ->
                    normalMode model (moveWithin activeId -1)

                "alt+k" ->
                    normalMode model (moveWithin activeId -1)

                "alt+down" ->
                    normalMode model (moveWithin activeId 1)

                "alt+j" ->
                    normalMode model (moveWithin activeId 1)

                "alt+left" ->
                    normalMode model (moveLeft activeId)

                "alt+h" ->
                    normalMode model (moveLeft activeId)

                "alt+right" ->
                    normalMode model (moveRight activeId)

                "alt+l" ->
                    normalMode model (moveRight activeId)

                "alt+shift+up" ->
                    normalMode model (moveWithin activeId -5)

                "alt+shift+down" ->
                    normalMode model (moveWithin activeId 5)

                "alt+pageup" ->
                    normalMode model (moveWithin activeId -999999)

                "alt+pagedown" ->
                    normalMode model (moveWithin activeId 999999)

                "home" ->
                    normalMode model (goToTopOfColumn activeId)

                "end" ->
                    normalMode model (goToBottomOfColumn activeId)

                "pageup" ->
                    normalMode model (goToTopOfGroup activeId True)

                "pagedown" ->
                    normalMode model (goToBottomOfGroup activeId True)

                "mod+x" ->
                    normalMode model (cut activeId)

                "mod+c" ->
                    normalMode model (copy activeId)

                "mod+b" ->
                    case vs.viewMode of
                        Normal _ ->
                            ( model
                            , Cmd.none
                            , []
                            )

                        _ ->
                            ( model
                            , send (TextSurround activeId "**")
                            , []
                            )

                "mod+i" ->
                    case vs.viewMode of
                        Normal _ ->
                            ( model
                            , Cmd.none
                            , []
                            )

                        _ ->
                            ( model
                            , send (TextSurround activeId "*")
                            , []
                            )

                "/" ->
                    case vs.viewMode of
                        Normal _ ->
                            ( model
                            , Task.attempt (\_ -> NoOp) (Browser.Dom.focus "search-input")
                            , []
                            )

                        _ ->
                            ( model
                            , Cmd.none
                            , []
                            )

                _ ->
                    ( model
                    , Cmd.none
                    , []
                    )

        WillPrint ->
            ( model, Cmd.none, [] )

        -- === Misc ===
        RecvCollabState collabState ->
            let
                newCollabs =
                    if List.member collabState.uid (vs.collaborators |> List.map .uid) then
                        vs.collaborators
                            |> List.map
                                (\c ->
                                    if c.uid == collabState.uid then
                                        collabState

                                    else
                                        c
                                )

                    else
                        collabState :: vs.collaborators

                newTree =
                    case collabState.mode of
                        CollabEditing editId ->
                            TreeStructure.update (TreeStructure.Upd editId collabState.field) model.workingTree

                        _ ->
                            model.workingTree
            in
            ( { model
                | workingTree = newTree
                , viewState = { vs | collaborators = newCollabs }
              }
            , Cmd.none
            , []
            )

        CollaboratorDisconnected uid ->
            ( { model
                | viewState =
                    { vs | collaborators = vs.collaborators |> List.filter (\c -> c.uid /= uid) }
              }
            , Cmd.none
            , []
            )

        -- === INTEGRATION TEST HOOKS ===
        TestTextImportLoaded _ ->
            ( model, Cmd.none, [] )


andThen : (ModelData -> ( ModelData, Cmd Msg, List MsgToParent )) -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
andThen f ( model, cmd, msgs ) =
    let
        ( newModel, nextCmd, newMsgs ) =
            f model
    in
    ( newModel, Cmd.batch [ cmd, nextCmd ], msgs ++ newMsgs )



-- === Card Activation ===


changeMode : ViewMode -> Bool -> ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
changeMode newViewMode instant model =
    let
        vs =
            model.viewState

        oldId =
            getActiveIdFromViewMode vs.viewMode

        tryId =
            getActiveIdFromViewMode newViewMode

        activeTree__ =
            getTree (getActiveIdFromViewMode newViewMode) model.workingTree.tree

        activeTree_ =
            case activeTree__ of
                Just aTree ->
                    Just aTree

                Nothing ->
                    getFirstCard model.workingTree.tree
    in
    case activeTree_ of
        Just activeTree ->
            let
                newPast =
                    if tryId == oldId then
                        vs.activePast

                    else
                        oldId :: vs.activePast |> List.take 40

                id =
                    activeTree.id

                desc =
                    activeTree
                        |> getDescendants
                        |> List.map .id

                anc =
                    getAncestors model.workingTree.tree activeTree []
                        |> List.map .id

                scrollPositions =
                    getScrollPositions activeTree newPast model.workingTree.tree

                colIdx =
                    getDepth 0 model.workingTree.tree activeTree.id

                newModel newVm =
                    { model
                        | viewState =
                            { vs
                                | viewMode = newVm
                                , activePast = newPast
                                , descendants = desc
                                , ancestors = anc
                            }
                    }
            in
            case ( vs.viewMode, newViewMode ) of
                ( Normal _, Normal newId ) ->
                    ( newModel newViewMode
                    , send (ScrollCards (id :: newPast) scrollPositions colIdx instant)
                    , []
                    )

                ( Normal _, Editing newEditData ) ->
                    ( model, Cmd.none, [] )

                ( Normal _, FullscreenEditing newEditData ) ->
                    ( model, Cmd.none, [] )

                ( Editing oldEditData, Normal newId ) ->
                    ( model, Cmd.none, [] )

                ( Editing oldEditData, Editing newEditData ) ->
                    ( model, Cmd.none, [] )

                ( Editing oldEditData, FullscreenEditing newEditData ) ->
                    ( model, Cmd.none, [] )

                ( FullscreenEditing oldEditData, Normal newId ) ->
                    ( model, Cmd.none, [] )

                ( FullscreenEditing oldEditData, Editing newEditData ) ->
                    ( model, Cmd.none, [] )

                ( FullscreenEditing oldEditData, FullscreenEditing newEditData ) ->
                    ( model, Cmd.none, [] )

        Nothing ->
            ( model, Cmd.none, [] )


activate : String -> Bool -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
activate tryId instant ( model, prevCmd, prevMsgsToParent ) =
    let
        vs =
            model.viewState

        oldId =
            getActiveId (Model model)
    in
    let
        activeTree__ =
            getTree tryId model.workingTree.tree

        activeTree_ =
            case activeTree__ of
                Just aTree ->
                    Just aTree

                Nothing ->
                    getFirstCard model.workingTree.tree
    in
    case activeTree_ of
        Nothing ->
            ( model, prevCmd, prevMsgsToParent )

        Just activeTree ->
            let
                newPast =
                    if tryId == oldId then
                        vs.activePast

                    else
                        oldId :: vs.activePast |> List.take 40

                id =
                    activeTree.id

                desc =
                    activeTree
                        |> getDescendants
                        |> List.map .id

                anc =
                    getAncestors model.workingTree.tree activeTree []
                        |> List.map .id

                newModel newVm =
                    { model
                        | viewState =
                            { vs
                                | viewMode = newVm
                                , activePast = newPast
                                , descendants = desc
                                , ancestors = anc
                            }
                    }
            in
            case vs.viewMode of
                FullscreenEditing _ ->
                    ( newModel (Normal "TODO")
                    , Cmd.batch [ prevCmd, send <| ScrollFullscreenCards id ]
                    , prevMsgsToParent
                    )

                _ ->
                    let
                        scrollPositions =
                            getScrollPositions activeTree newPast model.workingTree.tree

                        colIdx =
                            getDepth 0 model.workingTree.tree activeTree.id
                    in
                    ( newModel (Normal oldId)
                    , Cmd.batch
                        [ prevCmd
                        , send
                            (ScrollCards (id :: newPast) scrollPositions colIdx instant)
                        ]
                    , prevMsgsToParent
                    )


goLeft : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goLeft id ( model, prevCmd, prevMsgsToParent ) =
    let
        targetId =
            getParent id model.workingTree.tree |> Maybe.withDefault defaultTree |> .id
    in
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate targetId False


goDown : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goDown id ( model, prevCmd, prevMsgsToParent ) =
    let
        targetId =
            case getNextInColumn id model.workingTree.tree of
                Nothing ->
                    id

                Just ntree ->
                    ntree.id
    in
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate targetId False


goUp : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goUp id ( model, prevCmd, prevMsgsToParent ) =
    let
        targetId =
            case getPrevInColumn id model.workingTree.tree of
                Nothing ->
                    id

                Just ntree ->
                    ntree.id
    in
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate targetId False


goRight : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goRight id ( model, prevCmd, prevMsgsToParent ) =
    let
        vs =
            model.viewState

        tree_ =
            getTree id model.workingTree.tree

        childrenIds =
            getChildren (tree_ |> Maybe.withDefault defaultTree)
                |> List.map .id

        firstChildId =
            childrenIds
                |> List.head
                |> Maybe.withDefault id

        prevActiveOfChildren =
            vs.activePast
                |> List.filter (\a -> List.member a childrenIds)
                |> List.head
                |> Maybe.withDefault firstChildId
    in
    case tree_ of
        Nothing ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )

        Just _ ->
            if List.length childrenIds == 0 then
                ( model
                , prevCmd
                , prevMsgsToParent
                )

            else
                ( model
                , prevCmd
                , prevMsgsToParent
                )
                    |> activate prevActiveOfChildren False



-- === Card Editing  ===


saveCard : { cardId : String, field : String } -> ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
saveCard { cardId, field } model =
    let
        newTree =
            TreeStructure.update (TreeStructure.Upd cardId field) model.workingTree
    in
    if newTree.tree /= model.workingTree.tree then
        ( { model
            | workingTree = newTree
          }
        , Cmd.none
        , []
        )
            |> localSave (CTUpd cardId field)
            |> addToHistory

    else
        ( { model | dirty = False }
        , send <| SetDirty False
        , []
        )


saveAndStopEditing : ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
saveAndStopEditing model =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    case vs.viewMode of
        Normal active ->
            model |> openCard active (getContent active model.workingTree.tree)

        Editing _ ->
            ( model, Cmd.none, [] )
                |> saveCardIfEditing
                |> closeCard

        FullscreenEditing _ ->
            ( model, Cmd.none, [] )
                |> saveCardIfEditing
                |> closeCard
                |> activate activeId True


saveCardIfEditing : ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
saveCardIfEditing ( model, prevCmd, prevParentMsgs ) =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    case vs.viewMode of
        Normal _ ->
            ( model
            , prevCmd
            , prevParentMsgs
            )

        Editing { field } ->
            let
                newTree =
                    TreeStructure.update (TreeStructure.Upd activeId field) model.workingTree
            in
            if newTree.tree /= model.workingTree.tree then
                ( { model
                    | workingTree = newTree
                  }
                , prevCmd
                , prevParentMsgs
                )
                    |> localSave (CTUpd activeId field)
                    |> addToHistory

            else
                ( { model | dirty = False }
                , Cmd.batch [ prevCmd, send <| SetDirty False ]
                , prevParentMsgs
                )

        FullscreenEditing { field } ->
            let
                newTree =
                    TreeStructure.update (TreeStructure.Upd activeId field) model.workingTree
            in
            if newTree.tree /= model.workingTree.tree then
                ( { model
                    | workingTree = newTree
                  }
                , prevCmd
                , prevParentMsgs
                )
                    |> localSave (CTUpd activeId field)
                    |> addToHistory

            else
                ( { model | dirty = False }
                , Cmd.batch [ prevCmd, send <| SetDirty False ]
                , prevParentMsgs
                )


openCard : String -> String -> ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
openCard id str model =
    let
        vs =
            model.viewState

        ( newViewMode, maybeScroll ) =
            case vs.viewMode of
                Normal _ ->
                    ( Editing { cardId = id, field = str }, Cmd.none )

                FullscreenEditing _ ->
                    ( FullscreenEditing { cardId = id, field = str }, send <| ScrollFullscreenCards id )

                Editing oldStr ->
                    ( Editing oldStr, Cmd.none )
    in
    ( { model
        | viewState = { vs | viewMode = newViewMode }
      }
    , Cmd.batch [ focus id, maybeScroll ]
    , []
    )
        |> preventIfBlocked model


openCardFullscreen : String -> String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
openCardFullscreen id str ( model, prevCmd, prevMsgsToParent ) =
    ( model, prevCmd, prevMsgsToParent )
        |> andThen (openCard id str)
        |> (\( m, c, p ) ->
                let
                    vs =
                        m.viewState
                in
                ( { m | viewState = { vs | viewMode = FullscreenEditing { cardId = id, field = str } } }
                , Cmd.batch [ c, focus id ]
                , p
                )
           )


enterFullscreen : ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
enterFullscreen model =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    case vs.viewMode of
        Editing { field } ->
            ( { model
                | viewState =
                    { vs | viewMode = FullscreenEditing { cardId = activeId, field = field } }
              }
            , focus activeId
            , []
            )

        _ ->
            ( model, Cmd.none, [] )


exitFullscreen : ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
exitFullscreen model =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    case vs.viewMode of
        Normal _ ->
            ( model, Cmd.none, [] )

        Editing _ ->
            ( model, Cmd.none, [] )

        FullscreenEditing { field } ->
            ( { model | viewState = { vs | viewMode = Editing { cardId = activeId, field = field } } }
            , Cmd.batch [ send <| SetField activeId field, focus activeId ]
            , []
            )


exitFullscreenExposed : Model -> ( Model, Cmd Msg )
exitFullscreenExposed (Model model) =
    let
        ( newModel, cmd, _ ) =
            model |> exitFullscreen
    in
    ( Model newModel, cmd )


closeCard : ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
closeCard ( model, prevCmd, prevMsgsToParent ) =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    ( { model | viewState = { vs | viewMode = Normal activeId } }, prevCmd, prevMsgsToParent )


deleteCard : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
deleteCard id ( model, prevCmd, prevMsgsToParent ) =
    let
        vs =
            model.viewState

        isLocked =
            vs.collaborators
                |> List.filter (\c -> c.mode == CollabEditing id)
                |> (not << List.isEmpty)

        parent_ =
            getParent id model.workingTree.tree

        prev_ =
            getPrevInColumn id model.workingTree.tree

        next_ =
            getNextInColumn id model.workingTree.tree

        ( nextToActivate, isLastChild ) =
            case ( parent_, prev_, next_ ) of
                ( _, Just prev, _ ) ->
                    ( prev.id, False )

                ( _, Nothing, Just next ) ->
                    ( next.id, False )

                ( Just parent, Nothing, Nothing ) ->
                    ( parent.id, parent.id == "0" )

                ( Nothing, Nothing, Nothing ) ->
                    ( "0", True )
    in
    if isLocked then
        ( model
        , send (Alert "Card is being edited by someone else.")
        , prevMsgsToParent
        )
            |> preventIfBlocked model

    else if isLastChild then
        ( model
        , send (Alert "Cannot delete last card.")
        , prevMsgsToParent
        )
            |> preventIfBlocked model

    else
        ( { model
            | workingTree = TreeStructure.update (TreeStructure.Rmv id) model.workingTree
            , dirty = True
          }
        , Cmd.batch [ prevCmd, send <| SetDirty True ]
        , prevMsgsToParent
        )
            |> activate nextToActivate False
            |> localSave (CTRmv id)
            |> addToHistory
            |> preventIfBlocked model


goToTopOfColumn : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goToTopOfColumn id ( model, prevCmd, prevMsgsToParent ) =
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate (getFirstInColumn id model.workingTree.tree) False


goToBottomOfColumn : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goToBottomOfColumn id ( model, prevCmd, prevMsgsToParent ) =
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate (getLastInColumn id model.workingTree.tree) False


goToTopOfGroup : String -> Bool -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goToTopOfGroup id fallToNextGroup ( model, prevCmd, prevMsgsToParent ) =
    let
        topSibling =
            case
                getSiblings id model.workingTree.tree
                    |> List.head
            of
                Nothing ->
                    id

                Just lastSiblingTree ->
                    lastSiblingTree.id

        targetId =
            if topSibling == id && fallToNextGroup then
                case getPrevInColumn id model.workingTree.tree of
                    Nothing ->
                        topSibling

                    Just previousColumnTree ->
                        previousColumnTree.id

            else
                topSibling
    in
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate targetId False


goToBottomOfGroup : String -> Bool -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
goToBottomOfGroup id fallToNextGroup ( model, prevCmd, prevMsgsToParent ) =
    let
        bottomSibling =
            case
                getSiblings id model.workingTree.tree
                    |> List.reverse
                    |> List.head
            of
                Nothing ->
                    id

                Just lastSiblingTree ->
                    lastSiblingTree.id

        targetId =
            if bottomSibling == id && fallToNextGroup then
                case getNextInColumn id model.workingTree.tree of
                    Nothing ->
                        bottomSibling

                    Just nextColumnTree ->
                        nextColumnTree.id

            else
                bottomSibling
    in
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> activate targetId False


cancelCard : ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
cancelCard ( model, prevCmd, prevMsgsToParent ) =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)
    in
    ( { model
        | viewState = { vs | viewMode = Normal activeId }
      }
    , prevCmd
    , prevMsgsToParent
    )
        |> activate activeId True


intentCancelCard : ModelData -> ( ModelData, Cmd Msg, List MsgToParent )
intentCancelCard model =
    let
        vs =
            model.viewState

        activeId =
            getActiveId (Model model)

        originalContent =
            getContent activeId model.workingTree.tree
    in
    case vs.viewMode of
        Normal _ ->
            ( model
            , Cmd.none
            , []
            )

        _ ->
            ( model
            , send (ConfirmCancelCard activeId originalContent (tr (GlobalData.language model.globalData) AreYouSureCancel))
            , []
            )



-- === Card Insertion  ===


insert : String -> Int -> String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
insert pid pos initText ( model, prevCmd, prevMsgsToParent ) =
    let
        ( newId, newSeed ) =
            Random.step randomPositiveInt (GlobalData.seed model.globalData)

        newIdString =
            "node-" ++ (newId |> String.fromInt)
    in
    ( { model
        | workingTree = TreeStructure.update (TreeStructure.Ins newIdString initText pid pos) model.workingTree
        , globalData = GlobalData.setSeed newSeed model.globalData
      }
    , prevCmd
    , prevMsgsToParent
        ++ [ LocalSave
                (CTIns newIdString
                    initText
                    (if pid == "0" then
                        Nothing

                     else
                        Just pid
                    )
                    pos
                )
           ]
    )
        |> andThen (openCard newIdString initText)
        |> activate newIdString False
        |> preventIfBlocked model


insertRelative : String -> Int -> String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
insertRelative id delta initText ( model, prevCmd, prevMsgsToParent ) =
    let
        idx =
            getIndex id model.workingTree.tree |> Maybe.withDefault 999999

        pid_ =
            getParent id model.workingTree.tree |> Maybe.map .id
    in
    case pid_ of
        Just pid ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )
                |> insert pid (idx + delta) initText

        Nothing ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )


insertAbove : String -> String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
insertAbove id initText tup =
    insertRelative id 0 initText tup


insertBelow : String -> String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
insertBelow id initText ( model, prevCmd, prevMsgsToParent ) =
    insertRelative id 1 initText ( model, prevCmd, prevMsgsToParent )


insertChild : String -> String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
insertChild id initText ( model, prevCmd, prevMsgsToParent ) =
    ( model
    , prevCmd
    , prevMsgsToParent
    )
        |> insert id 999999 initText


mergeUp : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
mergeUp id ( model, prevCmd, prevMsgsToParent ) =
    let
        currentTree_ =
            getTree id model.workingTree.tree

        prevTree_ =
            getPrevInColumn id model.workingTree.tree
    in
    case ( currentTree_, prevTree_ ) of
        ( Just currentTree, Just prevTree ) ->
            let
                mergedTree =
                    model.workingTree
                        |> TreeStructure.update (TreeStructure.Mrg currentTree prevTree True)
            in
            ( { model
                | workingTree = mergedTree
              }
            , prevCmd
            , prevMsgsToParent
            )
                |> activate prevTree.id False
                |> localSave (CTMrg currentTree.id prevTree.id True)
                |> addToHistory

        _ ->
            ( model, prevCmd, prevMsgsToParent )


mergeDown : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
mergeDown id ( model, prevCmd, prevMsgsToParent ) =
    let
        currentTree_ =
            getTree id model.workingTree.tree

        nextTree_ =
            getNextInColumn id model.workingTree.tree
    in
    case ( currentTree_, nextTree_ ) of
        ( Just currentTree, Just nextTree ) ->
            let
                mergedTree =
                    model.workingTree
                        |> TreeStructure.update (TreeStructure.Mrg currentTree nextTree False)
            in
            ( { model
                | workingTree = mergedTree
              }
            , prevCmd
            , prevMsgsToParent
            )
                |> activate nextTree.id False
                |> localSave (CTMrg currentTree.id nextTree.id False)
                |> addToHistory

        _ ->
            ( model, prevCmd, prevMsgsToParent )


setCursorPosition : Int -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
setCursorPosition pos ( model, prevCmd, prevMsgsToParent ) =
    ( model, Cmd.batch [ prevCmd, send (SetCursorPosition pos) ], prevMsgsToParent )



-- === Card Moving  ===


move : Tree -> String -> Int -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
move subtree pid pos ( model, prevCmd, prevMsgsToParent ) =
    ( { model
        | workingTree = TreeStructure.update (TreeStructure.Mov subtree pid pos) model.workingTree
      }
    , prevCmd
    , prevMsgsToParent
    )
        |> activate subtree.id False
        |> localSave
            (CTMov subtree.id
                (if pid == "0" then
                    Nothing

                 else
                    Just pid
                )
                pos
            )
        |> addToHistory


moveWithin : String -> Int -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
moveWithin id delta ( model, prevCmd, prevMsgsToParent ) =
    let
        tree_ =
            getTree id model.workingTree.tree

        pid_ =
            getParent id model.workingTree.tree
                |> Maybe.map .id

        refIdx_ =
            getIndex id model.workingTree.tree
    in
    case ( tree_, pid_, refIdx_ ) of
        ( Just tree, Just pid, Just refIdx ) ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )
                |> move tree pid (refIdx + delta |> Basics.max 0)

        _ ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )


moveLeft : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
moveLeft id ( model, prevCmd, prevMsgsToParent ) =
    let
        tree_ =
            getTree id model.workingTree.tree

        parentId =
            getParent id model.workingTree.tree
                |> Maybe.map .id
                |> Maybe.withDefault "invalid"

        parentIdx_ =
            getIndex parentId model.workingTree.tree

        grandparentId_ =
            getParent parentId model.workingTree.tree
                |> Maybe.map .id
    in
    case ( tree_, grandparentId_, parentIdx_ ) of
        ( Just tree, Just gpId, Just refIdx ) ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )
                |> move tree gpId (refIdx + 1)

        _ ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )


moveRight : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
moveRight id ( model, prevCmd, prevMsgsToParent ) =
    let
        tree_ =
            getTree id model.workingTree.tree

        prev_ =
            getPrev id model.workingTree.tree
                |> Maybe.map .id
    in
    case ( tree_, prev_ ) of
        ( Just tree, Just prev ) ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )
                |> move tree prev 999999

        _ ->
            ( model
            , prevCmd
            , prevMsgsToParent
            )



-- === Card Cut/Copy/Paste ===


cut : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
cut id ( model, prevCmd, prevMsgsToParent ) =
    let
        parent_ =
            getParent id model.workingTree.tree

        prev_ =
            getPrevInColumn id model.workingTree.tree

        next_ =
            getNextInColumn id model.workingTree.tree

        isLastChild =
            case ( parent_, prev_, next_ ) of
                ( Just parent, Nothing, Nothing ) ->
                    parent.id == "0"

                _ ->
                    False
    in
    if isLastChild then
        ( model
        , send (Alert "Cannot cut last card")
        , prevMsgsToParent
        )

    else
        ( model, prevCmd, prevMsgsToParent )
            |> copy id
            |> deleteCard id


copy : String -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
copy id ( model, prevCmd, prevMsgsToParent ) =
    let
        vs =
            model.viewState

        copiedTree_ =
            getTree id model.workingTree.tree
    in
    ( { model
        | viewState = { vs | clipboardTree = copiedTree_ }
      }
    , Cmd.batch
        [ prevCmd
        , case copiedTree_ of
            Just tree ->
                send <| CopyCurrentSubtree <| treeToValue tree

            Nothing ->
                Cmd.none
        ]
    , prevMsgsToParent
    )


paste : Tree -> String -> Int -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
paste subtree pid pos ( model, prevCmd, prevMsgsToParent ) =
    ( { model
        | workingTree = TreeStructure.update (TreeStructure.Paste subtree pid pos) model.workingTree
      }
    , prevCmd
    , prevMsgsToParent
    )
        |> activate subtree.id False
        |> localSave (CTBlk subtree pid pos)
        |> addToHistory


pasteBelow : String -> Tree -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
pasteBelow id copiedTree ( model, prevCmd, prevMsgsToParent ) =
    let
        ( newId, newSeed ) =
            Random.step randomPositiveInt (GlobalData.seed model.globalData)

        treeToPaste =
            TreeStructure.renameNodes (newId |> String.fromInt) copiedTree

        pid =
            (getParent id model.workingTree.tree |> Maybe.map .id) |> Maybe.withDefault "0"

        pos =
            (getIndex id model.workingTree.tree |> Maybe.withDefault 0) + 1
    in
    ( { model | globalData = GlobalData.setSeed newSeed model.globalData }
    , prevCmd
    , prevMsgsToParent
    )
        |> paste treeToPaste pid pos


pasteInto : String -> Tree -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
pasteInto id copiedTree ( model, prevCmd, prevMsgsToParent ) =
    let
        ( newId, newSeed ) =
            Random.step randomPositiveInt (GlobalData.seed model.globalData)

        treeToPaste =
            TreeStructure.renameNodes (newId |> String.fromInt) copiedTree
    in
    ( { model | globalData = GlobalData.setSeed newSeed model.globalData }
    , prevCmd
    , prevMsgsToParent
    )
        |> paste treeToPaste id 999999



-- VIEW


type alias AppMsgs msg =
    { docMsg : Msg -> msg
    , keyboard : String -> msg
    , tooltipRequested : String -> TooltipPosition -> TranslationId -> msg
    , tooltipClosed : msg
    }


view : AppMsgs msg -> Model -> List (Html msg)
view appMsg (Model model) =
    if model.loading then
        UI.viewDocumentLoadingSpinner

    else
        viewLoaded appMsg model


viewLoaded : AppMsgs msg -> ModelData -> List (Html msg)
viewLoaded ({ docMsg } as appMsg) model =
    let
        activeId =
            getActiveId (Model model)

        activeTree_ =
            getTree activeId model.workingTree.tree

        mobileBtnMsg shortcut =
            appMsg.keyboard shortcut

        cardTitleReplacer ( id, inputString ) =
            case String.lines inputString of
                firstLine :: _ ->
                    ( id
                    , firstLine
                        |> String.trim
                        |> (\str ->
                                if String.isEmpty str then
                                    "(empty)"

                                else
                                    str
                           )
                    )

                [] ->
                    ( id, "(empty)" )

        cardTitles =
            case activeTree_ of
                Just activeTree ->
                    (getAncestors model.workingTree.tree activeTree []
                        |> List.map (\t -> ( t.id, t.content ))
                        |> List.drop 1
                    )
                        ++ [ ( activeTree.id, activeTree.content ) ]
                        |> List.map cardTitleReplacer

                Nothing ->
                    []
    in
    [ lazy4 treeView (GlobalData.language model.globalData) (GlobalData.isMac model.globalData) model.viewState model.workingTree |> Html.map docMsg
    , if (not << List.isEmpty) cardTitles then
        UI.viewBreadcrumbs Activate cardTitles |> Html.map docMsg

      else
        text ""
    ]
        ++ [ viewSearchField SearchFieldUpdated model |> Html.map docMsg
           , viewMobileButtons
                { edit = mobileBtnMsg "mod+enter"
                , save = mobileBtnMsg "mod+enter"
                , cancel = mobileBtnMsg "esc"
                , plusDown = mobileBtnMsg "mod+down"
                , plusUp = mobileBtnMsg "mod+up"
                , plusRight = mobileBtnMsg "mod+right"
                , navLeft = mobileBtnMsg "left"
                , navUp = mobileBtnMsg "up"
                , navDown = mobileBtnMsg "down"
                , navRight = mobileBtnMsg "right"
                }
                (case model.viewState.viewMode of
                    Normal _ ->
                        False

                    _ ->
                        True
                )
           , Keyed.node "div" [ style "display" "contents" ] [ ( "randomstringforloadingoverlay", div [ id "loading-overlay" ] [] ) ]
           , div [ id "preloader" ] []
           ]


treeView : Language -> Bool -> ViewState -> TreeStructure.Model -> Html Msg
treeView lang isMac vstate model =
    let
        activeId =
            getActiveIdFromViewState vstate

        searchFilter term_ cols =
            case term_ of
                Just term ->
                    let
                        hasTerm tree =
                            term
                                |> Regex.fromStringWith { caseInsensitive = True, multiline = False }
                                |> Maybe.withDefault Regex.never
                                |> (\t -> Regex.contains t tree.content)
                    in
                    cols
                        |> List.map (\c -> List.map (\g -> List.filter hasTerm g) c)

                Nothing ->
                    cols

        columnsFiltered =
            model.columns
                |> searchFilter vstate.searchField
                |> List.drop 1

        getViewArgs c =
            let
                editing_ =
                    case vstate.viewMode of
                        Normal _ ->
                            VisibleNormal

                        Editing _ ->
                            if c |> List.concat |> List.map .id |> List.member activeId then
                                VisibleEditing

                            else
                                VisibleNormal

                        FullscreenEditing _ ->
                            -- TODO : Impossible state
                            VisibleFullscreenEditing
            in
            VisibleViewState
                activeId
                editing_
                vstate.descendants
                vstate.ancestors
                vstate.dragModel
                vstate.collaborators
                lang
                isMac

        columns =
            columnsFiltered
                |> List.map (\c -> lazy2 viewColumn (getViewArgs c) c)
    in
    div
        [ id "document"
        ]
        [ div [ class "left-padding-column" ] []
        , div [ id "column-container" ]
            columns
        , div [ class "right-padding-column" ] []
        ]


viewColumn : VisibleViewState -> Column -> Html Msg
viewColumn vstate col =
    let
        buffer =
            [ div [ class "buffer" ] [] ]
    in
    div
        [ class "column" ]
        (buffer
            ++ List.map (lazy2 viewGroup vstate) col
            ++ buffer
        )


viewGroup : VisibleViewState -> Group -> Html Msg
viewGroup vstate xs =
    let
        firstChild =
            xs
                |> List.head
                |> Maybe.withDefault defaultTree
                |> .id

        lastChild =
            xs
                |> List.reverse
                |> List.head
                |> Maybe.withDefault defaultTree
                |> .id

        hasActive =
            xs
                |> List.map .id
                |> List.member vstate.active

        isActiveDescendant =
            vstate.descendants
                |> List.member firstChild

        viewFunction t =
            let
                isActive =
                    t.id == vstate.active

                isAncestor =
                    List.member t.id vstate.ancestors

                isEditing =
                    case vstate.viewMode of
                        VisibleEditing ->
                            t.id == vstate.active

                        VisibleNormal ->
                            False

                        VisibleFullscreenEditing ->
                            -- TODO : Impossible state
                            False

                isLast =
                    t.id == lastChild

                collabsEditingCard =
                    vstate.collaborators
                        |> List.filter (\c -> c.mode == CollabEditing t.id)
                        |> List.map .uid

                collabsOnCard =
                    vstate.collaborators
                        |> List.filter (\c -> c.mode == CollabActive t.id || c.mode == CollabEditing t.id)
                        |> List.map .uid
            in
            if isActive && not isEditing then
                ( t.id, lazy8 viewCardActive vstate.language t.id t.content (hasChildren t) isLast collabsOnCard collabsEditingCard vstate.dragModel )

            else if isEditing then
                ( t.id, lazy5 viewCardEditing vstate.language t.id t.content (hasChildren t) vstate.isMac )

            else
                ( t.id, lazy7 viewCardOther t.id t.content isEditing (hasChildren t) isAncestor isLast vstate.dragModel )
    in
    Keyed.node "div"
        [ classList
            [ ( "group", True )
            , ( "has-active", hasActive )
            , ( "active-descendant", isActiveDescendant )
            ]
        ]
        (List.map viewFunction xs
            ++ (if isActiveDescendant then
                    [ ( "fillet-top-left", UI.fillet "top-left" )
                    , ( "fillet-bottom-left", UI.fillet "bottom-left" )
                    , ( "fillet-top-right", UI.fillet "top-right" )
                    , ( "fillet-bottom-right", UI.fillet "bottom-right" )
                    ]

                else
                    []
               )
        )


viewCardOther : String -> String -> Bool -> Bool -> Bool -> Bool -> ( DragDrop.Model String DropId, DragExternalModel ) -> Html Msg
viewCardOther cardId content isEditing isParent isAncestor isLast dragModels =
    div
        [ id ("card-" ++ cardId)
        , dir "auto"
        , classList
            [ ( "card", True )
            , ( "ancestor", isAncestor )
            , ( "has-children", isParent )
            ]
        ]
        ((if not isEditing then
            [ div ([ class "drag-region", title "Drag to move" ] ++ DragDrop.draggable DragDropMsg cardId) [ div [ class "handle" ] [] ] ]

          else
            []
         )
            ++ dropRegions cardId isEditing isLast dragModels
            ++ [ div
                    [ class "view"
                    , onClick (Activate cardId)
                    , onDoubleClick (OpenCard cardId content)
                    ]
                    [ lazy2 viewContent cardId content ]
               ]
        )


viewCardActive : Language -> String -> String -> Bool -> Bool -> List String -> List String -> ( DragDrop.Model String DropId, DragExternalModel ) -> Html Msg
viewCardActive lang cardId content isParent isLast collabsOnCard collabsEditingCard dragModels =
    let
        buttons =
            [ div [ class "flex-row card-top-overlay" ]
                [ span
                    [ class "card-btn ins-above"
                    , title <| tr lang InsertAboveTitle
                    , onClick (InsertAbove cardId)
                    ]
                    [ text "+" ]
                ]
            , div [ class "flex-column card-right-overlay" ]
                [ span
                    [ class "card-btn delete"
                    , title <| tr lang DeleteCardTitle
                    , onClick (DeleteCard cardId)
                    ]
                    []
                , span
                    [ class "card-btn ins-right"
                    , title <| tr lang InsertChildTitle
                    , onClick (InsertChild cardId)
                    ]
                    [ text "+" ]
                , span
                    [ class "card-btn edit"
                    , title <| tr lang EditCardTitle
                    , onClick (OpenCard cardId content)
                    ]
                    []
                ]
            , div [ class "flex-row card-bottom-overlay" ]
                [ span
                    [ class "card-btn ins-below"
                    , title <| tr lang InsertBelowTitle
                    , onClick (InsertBelow cardId)
                    ]
                    [ text "+" ]
                ]
            , viewIf isParent <| UI.fillet "top-right"
            , viewIf isParent <| UI.fillet "bottom-right"
            ]
    in
    div
        [ id ("card-" ++ cardId)
        , dir "auto"
        , classList
            [ ( "card", True )
            , ( "active", True )
            , ( "collab-active", not (List.isEmpty collabsOnCard) )
            , ( "collab-editing", not (List.isEmpty collabsEditingCard) )
            , ( "has-children", isParent )
            ]
        ]
        ([ div ([ class "drag-region", title "Drag to move" ] ++ DragDrop.draggable DragDropMsg cardId) [ div [ class "handle" ] [] ] ]
            ++ buttons
            ++ dropRegions cardId False isLast dragModels
            ++ [ div
                    [ class "view"
                    , onClick (Activate cardId)
                    , onDoubleClick (OpenCard cardId content)
                    ]
                    [ lazy2 viewContent cardId content ]
               , collabsSpan collabsOnCard collabsEditingCard
               ]
        )


viewCardEditing : Language -> String -> String -> Bool -> Bool -> Html Msg
viewCardEditing lang cardId content isParent _ =
    div
        [ id ("card-" ++ cardId)
        , dir "auto"
        , classList
            [ ( "card", True )
            , ( "active", True )
            , ( "editing", True )
            , ( "has-children", isParent )
            ]
        , attribute "data-cloned-content" content
        ]
        [ textarea
            [ id ("card-edit-" ++ cardId)
            , dir "auto"
            , classList
                [ ( "edit", True )
                , ( "mousetrap", True )
                ]
            , attribute "data-private" "lipsum"
            , onInput <| UpdateEditingField cardId
            , value content
            ]
            []
        , div [ class "flex-column card-right-overlay" ]
            [ div
                [ class "fullscreen-card-btn"
                , title "Edit in Fullscreen"
                , onClick EditToFullscreenMode
                ]
                [ AntIcons.fullscreenOutlined [ Attributes.width 16, Attributes.height 16 ] ]
            , div
                [ class "card-btn save"
                , title <| tr lang SaveChangesTitle
                , onClick SaveAndCloseCard
                ]
                []
            ]
        ]



-- HELPERS


hasChildren : Tree -> Bool
hasChildren { children } =
    case children of
        Children c ->
            (c
                |> List.length
            )
                /= 0


dropRegions : String -> Bool -> Bool -> ( DragDrop.Model String DropId, DragExternalModel ) -> List (Html Msg)
dropRegions cardId isEditing isLast ( dragModel, dragExternalModel ) =
    let
        dragId_ =
            DragDrop.getDragId dragModel

        dropId_ =
            DragDrop.getDropId dragModel

        dropDiv str dId =
            div
                ([ classList
                    [ ( "drop-region-" ++ str, True )
                    , ( "drop-hover", dropId_ == Just dId )
                    ]
                 ]
                    ++ DragDrop.droppable DragDropMsg dId
                )
                []

        dropDivExternal str dId =
            div
                [ classList
                    [ ( "drop-region-" ++ str, True )
                    , ( "drop-hover", .dropId dragExternalModel == Just dId )
                    ]
                , onWithOptions "dragenter" { stopPropagation = True, preventDefault = True } <| Json.succeed <| DragExternal <| DragEnter dId
                , onWithOptions "dragleave" { stopPropagation = True, preventDefault = True } <| Json.succeed <| DragExternal <| DragLeave dId
                ]
                []
    in
    case ( dragId_, dragExternalModel.isDragging, isEditing ) of
        ( Just _, _, False ) ->
            [ dropDiv "above" (Above cardId)
            , dropDiv "into" (Into cardId)
            ]
                ++ (if isLast then
                        [ dropDiv "below" (Below cardId) ]

                    else
                        []
                   )

        ( Nothing, True, False ) ->
            [ dropDivExternal "above" (Above cardId)
            , dropDivExternal "into" (Into cardId)
            ]
                ++ (if isLast then
                        [ dropDivExternal "below" (Below cardId) ]

                    else
                        []
                   )

        _ ->
            []


preventIfBlocked : ModelData -> ( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )
preventIfBlocked originalModel ( newModel, cmd, parentMsgs ) =
    case originalModel.block of
        Nothing ->
            ( newModel, cmd, parentMsgs )

        Just blockReason ->
            ( originalModel, send <| Alert blockReason, [] )


viewContent : String -> String -> Html Msg
viewContent cardId content =
    let
        options =
            { githubFlavored = Just { tables = True, breaks = True }
            , defaultHighlighting = Nothing
            , sanitize = False
            , smartypants = False
            }

        processedContent =
            let
                checkboxes =
                    Regex.fromStringWith { caseInsensitive = True, multiline = True }
                        "\\[(x| )\\]"
                        |> Maybe.withDefault Regex.never

                openAddDiff =
                    Regex.fromString "{\\+\\+" |> Maybe.withDefault Regex.never

                closeAddDiff =
                    Regex.fromString "\\+\\+}" |> Maybe.withDefault Regex.never

                openDelDiff =
                    Regex.fromString "{--" |> Maybe.withDefault Regex.never

                closeDelDiff =
                    Regex.fromString "--}" |> Maybe.withDefault Regex.never

                checkboxReplacer { match, number } =
                    let
                        checkState =
                            if match == "[x]" || match == "[X]" then
                                "checked"

                            else
                                ""
                    in
                    "<input type='checkbox'"
                        ++ checkState
                        ++ " onClick='checkboxClicked(\""
                        ++ cardId
                        ++ "\", "
                        ++ String.fromInt number
                        ++ ")'/>"
            in
            content
                |> Regex.replace openAddDiff (\_ -> "<ins class='diff'>")
                |> Regex.replace closeAddDiff (\_ -> "</ins>")
                |> Regex.replace openDelDiff (\_ -> "<del class='diff'>")
                |> Regex.replace closeDelDiff (\_ -> "</del>")
                |> Regex.replace checkboxes checkboxReplacer
    in
    Markdown.toHtmlWith options
        [ attribute "data-private" "lipsum" ]
        processedContent


collabsSpan : List String -> List String -> Html Msg
collabsSpan collabsOnCard collabsEditingCard =
    let
        collabsString =
            collabsOnCard
                |> List.map
                    (\c ->
                        if List.member c collabsEditingCard then
                            c ++ " is editing"

                        else
                            c
                    )
                |> String.join ", "
    in
    span [ class "collaborators" ] [ text collabsString ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions (Model model) =
    Sub.batch
        [ if model.dirty then
            Time.every (241 * 1000) (always AutoSave)

          else
            Sub.none
        ]


setTree : Tree -> Model -> ( Model, Cmd Msg, List MsgToParent )
setTree tree (Model model) =
    { model
        | workingTree = TreeStructure.setTree tree model.workingTree
    }
        |> (\m -> ( m, Cmd.none, [] ))
        |> activate (getActiveId (Model model)) False
        |> (\( m, c, msgs ) -> ( Model m, c, msgs ))


setWorkingTree : TreeStructure.Model -> Model -> Model
setWorkingTree workingTree (Model model) =
    Model
        { model | workingTree = workingTree }



-- Temporary getters & setters until I move these fields to parent


isDirty : Model -> Bool
isDirty (Model model) =
    model
        |> .dirty


isFullscreen : Model -> Bool
isFullscreen (Model model) =
    model
        |> .viewState
        |> .viewMode
        |> (\vm ->
                case vm of
                    FullscreenEditing _ ->
                        True

                    _ ->
                        False
           )


isNormalMode : Model -> Bool
isNormalMode (Model model) =
    model
        |> .viewState
        |> .viewMode
        |> (\vm ->
                case vm of
                    Normal _ ->
                        True

                    _ ->
                        False
           )


getViewMode : Model -> ViewMode
getViewMode (Model model) =
    model
        |> .viewState
        |> .viewMode


getActiveId : Model -> String
getActiveId (Model model) =
    case model.viewState.viewMode of
        FullscreenEditing { cardId } ->
            cardId

        Editing { cardId } ->
            cardId

        Normal id ->
            id


getActiveIdFromViewMode : ViewMode -> String
getActiveIdFromViewMode viewMode =
    case viewMode of
        FullscreenEditing { cardId } ->
            cardId

        Editing { cardId } ->
            cardId

        Normal id ->
            id


getActiveIdFromViewState : ViewState -> String
getActiveIdFromViewState viewState =
    case viewState.viewMode of
        FullscreenEditing { cardId } ->
            cardId

        Editing { cardId } ->
            cardId

        Normal id ->
            id


lastActives : Result Json.Error (List String) -> Model -> ( Model, Cmd Msg )
lastActives activesResult (Model prevModel) =
    let
        vs =
            prevModel.viewState

        ( newViewState, maybeScroll ) =
            case activesResult of
                Ok (lastActive :: activePast) ->
                    let
                        newViewMode =
                            case vs.viewMode of
                                FullscreenEditing { field } ->
                                    FullscreenEditing { cardId = lastActive, field = field }

                                Editing { field } ->
                                    Editing { cardId = lastActive, field = field }

                                Normal _ ->
                                    Normal lastActive
                    in
                    ( { vs | viewMode = newViewMode, activePast = activePast }
                    , activate lastActive True
                    )

                Ok _ ->
                    ( vs, activate "1" True )

                Err _ ->
                    ( vs, identity )
    in
    ( { prevModel | viewState = newViewState }, Cmd.none, [] )
        |> maybeScroll
        |> (\( m, c, _ ) -> ( Model m, c ))


getField : Model -> String
getField (Model model) =
    case model.viewState.viewMode of
        FullscreenEditing { field } ->
            field

        Editing { field } ->
            field

        Normal _ ->
            ""


openCardFullscreenMsg : String -> String -> Model -> ( Model, Cmd Msg )
openCardFullscreenMsg cardId str (Model model) =
    ( model, Cmd.none, [] )
        |> saveCardIfEditing
        |> openCardFullscreen cardId str
        |> (\( m, c, _ ) -> ( Model m, c ))


updateField : String -> String -> Model -> ( Model, Cmd Msg )
updateField id field (Model model) =
    let
        vs =
            model.viewState
    in
    case vs.viewMode of
        Editing { cardId } ->
            ( { model
                | viewState = { vs | viewMode = Editing { cardId = cardId, field = field } }
                , dirty = True
              }
            , send <| SetDirty True
            , []
            )
                |> activate id False
                |> (\( m, c, _ ) -> ( Model m, c ))

        FullscreenEditing { cardId } ->
            ( { model
                | viewState =
                    { vs | viewMode = FullscreenEditing { cardId = cardId, field = field } }
                , dirty = True
              }
            , send <| SetDirty True
            , []
            )
                |> activate id False
                |> (\( m, c, _ ) -> ( Model m, c ))

        Normal _ ->
            ( Model model, Cmd.none )


getTextCursorInfo : Model -> TextCursorInfo
getTextCursorInfo (Model model) =
    model
        |> .textCursorInfo


setDirty : Bool -> Model -> Model
setDirty dirty (Model model) =
    Model { model | dirty = dirty }


getGlobalData : Model -> GlobalData
getGlobalData (Model model) =
    model
        |> .globalData


setGlobalData : GlobalData -> Model -> Model
setGlobalData globalData (Model model) =
    Model
        { model
            | globalData = globalData
        }


setBlock : Maybe String -> Model -> Model
setBlock block_ (Model model) =
    Model { model | block = block_ }


setLoading : Bool -> Model -> Model
setLoading loading (Model model) =
    Model
        { model
            | loading = loading
        }


getWorkingTree : Model -> TreeStructure.Model
getWorkingTree (Model model) =
    model
        |> .workingTree


getActiveTree : Model -> Maybe Tree
getActiveTree (Model model) =
    getTree (getActiveId (Model model)) model.workingTree.tree



-- HELPERS


focus : String -> Cmd Msg
focus id =
    Task.attempt (\_ -> NoOp) (Browser.Dom.focus ("card-edit-" ++ id))


normalMode : ModelData -> (( ModelData, Cmd Msg, List MsgToParent ) -> ( ModelData, Cmd Msg, List MsgToParent )) -> ( ModelData, Cmd Msg, List MsgToParent )
normalMode model operation =
    ( model
    , Cmd.none
    , []
    )
        |> (case model.viewState.viewMode of
                Normal _ ->
                    operation

                _ ->
                    identity
           )


onWithOptions :
    String
    ->
        { stopPropagation : Bool
        , preventDefault : Bool
        }
    -> Json.Decoder msg
    -> Attribute msg
onWithOptions name { stopPropagation, preventDefault } decoder =
    decoder
        |> Json.map (\msg -> { message = msg, stopPropagation = stopPropagation, preventDefault = preventDefault })
        |> custom name
