module Pages.Editor.State.Working exposing (..)

import Data.Entity as Entity exposing (Entity(..))
import Data.Jwt exposing (Jwt)
import Data.Replaceable as Replaceable exposing (Replaceable)
import Ellie.Types.Revision as Revision exposing (Revision)
import Ellie.Types.Settings as Settings exposing (Settings)
import Ellie.Types.User as User exposing (User)
import Elm.Compiler.Error as Error exposing (Error)
import Elm.Package as Package exposing (Package)
import Pages.Editor.Effects.Inbound as Inbound exposing (Inbound)
import Pages.Editor.Effects.Outbound as Outbound exposing (Outbound)
import Pages.Editor.Route as Route
import Pages.Editor.State.Actions as Actions


type Compilation
    = Ready
    | Compiling
    | FinishedWithErrors (List Error)
    | Succeeded


type alias Model =
    { elmCode : String
    , htmlCode : String
    , packages : List Package
    , projectName : String
    , token : Jwt
    , defaultPackages : List Package
    , revision : Replaceable Revision.Id Revision
    , actions : Actions.Model
    , user : User
    , compilation : Compilation
    , currentErrors : List Error
    , connected : Bool
    , animating : Bool
    , workbenchRatio : Float
    , actionsRatio : Float
    , editorsRatio : Float
    }


init : Jwt -> User -> Maybe (Entity Revision.Id Revision) -> List Package -> ( Model, Outbound Msg )
init token user revision defaultPackages =
    ( { elmCode = revision |> Maybe.map (Entity.record >> .elmCode) |> Maybe.withDefault defaultElm
      , htmlCode = revision |> Maybe.map (Entity.record >> .htmlCode) |> Maybe.withDefault defaultHtml
      , packages = revision |> Maybe.map (Entity.record >> .packages) |> Maybe.withDefault defaultPackages
      , projectName = ""
      , token = token
      , defaultPackages = defaultPackages
      , revision = Replaceable.fromMaybe revision
      , actions = Actions.Packages { query = "", searchedPackages = Nothing, awaitingSearch = False }
      , compilation = Ready
      , currentErrors = []
      , connected = True
      , animating = True
      , user = user
      , workbenchRatio = 0.5
      , actionsRatio = 0.1
      , editorsRatio = 0.75
      }
    , Outbound.Delay 1000 AnimationFinished
    )


defaultElm : String
defaultElm =
    """module Main exposing (main)

import Html exposing (Html, text)


main : Html msg
main =
    text "Hello, World!"
"""


defaultHtml : String
defaultHtml =
    """<html>
<head>
  <style>
    /* you can style your program here */
  </style>
</head>
<body>
  <script>
    var app = Elm.Main.fullscreen()
    // you can use ports and stuff here
  </script>
</body>
</html>
"""


shouldCheckNavigation : Model -> Bool
shouldCheckNavigation model =
    case Replaceable.toMaybe model.revision of
        Nothing ->
            (model.elmCode /= defaultElm)
                || (model.htmlCode /= defaultHtml)
                || (model.packages /= model.defaultPackages)

        Just (Entity _ revision) ->
            (model.elmCode /= revision.elmCode)
                || (model.htmlCode /= revision.htmlCode)
                || (model.packages /= revision.packages)


type Msg
    = ElmCodeChanged String
    | HtmlCodeChanged String
    | RouteChanged Route.Route
    | RevisionLoaded (Entity Revision.Id Revision)
    | ActionsMsg Actions.Msg
    | AnimationFinished
    | SettingsChanged Settings
    | ActionPaneSelected Actions.Model
    | WorkbenchResized Float
    | ActionsResized Float
    | EditorsResized Float
    | ChangedProjectName String
    | PackageInstalled Package
    | PackageUninstalled Package
    | FormatRequested
    | FormatCompleted String
    | CollapseHtml
    | CompileRequested
    | CompileFinished (List Error)
    | OnlineStatusChanged Bool
    | NoOp


update : Msg -> Model -> ( Model, Outbound Msg )
update msg ({ user } as model) =
    case msg of
        OnlineStatusChanged connected ->
            ( { model | connected = connected }
            , Outbound.none
            )

        CompileRequested ->
            ( model
            , Outbound.Compile model.token model.elmCode model.htmlCode model.packages
            )

        FormatRequested ->
            ( model
            , Outbound.FormatElmCode model.elmCode FormatCompleted
            )

        FormatCompleted code ->
            ( { model | elmCode = code }
            , Outbound.none
            )

        CollapseHtml ->
            ( if model.editorsRatio == 1 then
                { model | editorsRatio = 0.75 }
              else
                { model | editorsRatio = 1 }
            , Outbound.none
            )

        PackageInstalled package ->
            ( { model | packages = model.packages ++ [ package ] }
            , Outbound.none
            )

        PackageUninstalled package ->
            ( { model | packages = List.filter ((/=) package) model.packages }
            , Outbound.none
            )

        ChangedProjectName projectName ->
            ( { model | projectName = projectName }
            , Outbound.none
            )

        WorkbenchResized ratio ->
            ( { model | workbenchRatio = ratio }
            , Outbound.none
            )

        ActionsResized ratio ->
            ( { model | actionsRatio = ratio }
            , Outbound.none
            )

        EditorsResized ratio ->
            ( { model | editorsRatio = ratio }
            , Outbound.none
            )

        ActionPaneSelected actions ->
            ( { model | actions = actions }
            , Outbound.none
            )

        SettingsChanged settings ->
            ( { model | user = { user | settings = settings } }
            , Outbound.SaveSettings model.token settings
            )

        AnimationFinished ->
            ( { model | animating = False }, Outbound.none )

        NoOp ->
            ( model, Outbound.none )

        ActionsMsg actionsMsg ->
            Actions.update actionsMsg model.actions
                |> Tuple.mapFirst (\a -> { model | actions = a })
                |> Tuple.mapSecond (Outbound.map ActionsMsg)

        ElmCodeChanged code ->
            ( { model | elmCode = code }
            , Outbound.EnableNavigationCheck <| shouldCheckNavigation model
            )

        HtmlCodeChanged code ->
            ( { model | htmlCode = code }
            , Outbound.EnableNavigationCheck <| shouldCheckNavigation model
            )

        CompileFinished errors ->
            ( { model | currentErrors = errors }
            , Outbound.none
            )

        RevisionLoaded ((Entity revisionId _) as entity) ->
            case model.revision of
                Replaceable.Loading rid ->
                    if rid == revisionId then
                        ( Tuple.first <| init model.token model.user (Just entity) model.defaultPackages
                        , Outbound.none
                        )
                    else
                        ( model, Outbound.none )

                Replaceable.Replacing rid _ ->
                    if rid == revisionId then
                        ( Tuple.first <| init model.token model.user (Just entity) model.defaultPackages
                        , Outbound.none
                        )
                    else
                        ( model, Outbound.none )

                _ ->
                    ( model, Outbound.none )

        RouteChanged route ->
            case route of
                Route.Existing newRevisionId ->
                    case model.revision of
                        Replaceable.Loaded (Entity rid r) ->
                            if newRevisionId /= rid then
                                ( { model | revision = Replaceable.Replacing newRevisionId (Entity rid r) }
                                , Outbound.GetRevision newRevisionId RevisionLoaded
                                )
                            else
                                ( model, Outbound.none )

                        Replaceable.Loading rid ->
                            if newRevisionId /= rid then
                                ( { model | revision = Replaceable.Loading newRevisionId }
                                , Outbound.GetRevision newRevisionId RevisionLoaded
                                )
                            else
                                ( model, Outbound.none )

                        Replaceable.Replacing rid entity ->
                            if newRevisionId /= rid then
                                ( { model | revision = Replaceable.Replacing newRevisionId entity }
                                , Outbound.GetRevision newRevisionId RevisionLoaded
                                )
                            else
                                ( model, Outbound.none )

                        Replaceable.NotAsked ->
                            ( { model | revision = Replaceable.Loading newRevisionId }
                            , Outbound.GetRevision newRevisionId RevisionLoaded
                            )

                Route.New ->
                    case model.revision of
                        Replaceable.NotAsked ->
                            ( model, Outbound.none )

                        _ ->
                            ( Tuple.first <| init model.token model.user Nothing model.defaultPackages
                            , Outbound.none
                            )

                Route.NotFound ->
                    case Replaceable.toMaybe model.revision of
                        Just (Entity rid _) ->
                            ( model
                            , Outbound.Redirect <| Route.toString <| Route.Existing rid
                            )

                        Nothing ->
                            ( model
                            , Outbound.Redirect <| Route.toString Route.New
                            )


subscriptions : Model -> Inbound Msg
subscriptions model =
    Inbound.batch
        [ Inbound.KeepWorkspaceOpen model.token
        , Inbound.map ActionsMsg <| Actions.subscriptions model.actions
        , Inbound.CompileFinished model.token CompileFinished
        , if model.connected then
            Inbound.WorkspaceDetached model.token (OnlineStatusChanged False)
          else
            Inbound.WorkspaceAttached model.token (\_ -> OnlineStatusChanged True)
        ]
