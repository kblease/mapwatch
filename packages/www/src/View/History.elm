module View.History exposing (view, viewHistoryRun, viewDurationSet, formatMaybeDuration, viewDurationDelta)

import Html as H
import Html.Attributes as A
import Html.Events as E
import Time
import Date
import Dict
import Regex
import Maybe.Extra
import Model as Model exposing (Model, Msg(..))
import Mapwatch as Mapwatch
import Mapwatch.Instance as Instance exposing (Instance)
import Mapwatch.Run as Run exposing (Run)
import Mapwatch.Zone as Zone
import Route
import View.Nav
import View.Setup
import View.NotFound
import View.Home exposing (maskedText, viewHeader, viewParseError, viewProgress, viewInstance, viewDate, formatDuration, formatSideAreaType, viewSideAreaName)
import View.Icon as Icon
import View.Util exposing (roundToPlaces, viewSearch, pluralize, viewGoalForm, viewDateSearch)


view : Route.HistoryParams -> Model -> H.Html Msg
view params model =
    if Mapwatch.isReady model.mapwatch && not (isValidPage params.page model) then
        View.NotFound.view
    else
        H.div [ A.class "main" ]
            [ viewHeader
            , View.Nav.view <| Just model.route
            , View.Setup.view model
            , viewParseError model.mapwatch.parseError
            , viewBody params model
            ]


viewBody : Route.HistoryParams -> Model -> H.Html Msg
viewBody params model =
    case model.mapwatch.progress of
        Nothing ->
            -- waiting for file input, nothing to show yet
            H.div [] []

        Just p ->
            H.div [] <|
                (if Mapwatch.isProgressDone p then
                    -- all done!
                    [ viewMain params model ]
                 else
                    []
                )
                    ++ [ viewProgress p ]


perPage =
    25


numPages : Int -> Int
numPages numItems =
    ceiling <| (toFloat numItems) / (toFloat perPage)


isValidPage : Int -> Model -> Bool
isValidPage page model =
    case model.mapwatch.progress of
        Nothing ->
            True

        Just _ ->
            page == (clamp 0 (numPages (List.length model.mapwatch.runs) - 1) page)


viewMain : Route.HistoryParams -> Model -> H.Html Msg
viewMain params model =
    let
        currentRun : Maybe Run
        currentRun =
            -- include the current run if we're viewing a snapshot
            Maybe.andThen (\b -> Run.current b model.mapwatch.instance model.mapwatch.runState) params.before

        runs =
            model.mapwatch.runs
                |> (++) (Maybe.Extra.toList currentRun)
                |> Maybe.Extra.unwrap identity Run.search params.search
                |> Run.filterBetween params
                |> Run.sort params.sort
    in
        H.div []
            [ H.div []
                [ viewSearch [ A.placeholder "area name" ]
                    (\q ->
                        { params
                            | search =
                                if q == "" then
                                    Nothing
                                else
                                    Just q
                        }
                            |> HistorySearch
                    )
                    params.search
                , viewDateSearch (\qs1 -> Route.History { params | before = qs1.before, after = qs1.after }) params
                , viewGoalForm (\goal -> Model.RouteTo <| Route.History { params | goal = goal }) params
                ]
            , viewStatsTable params model.now runs
            , viewHistoryTable params runs model
            ]


viewStatsTable : Route.HistoryParams -> Date.Date -> List Run -> H.Html msg
viewStatsTable qs now runs =
    H.table [ A.class "history-stats" ]
        [ H.tbody []
            (case ( qs.after, qs.before ) of
                ( Nothing, Nothing ) ->
                    List.concat
                        [ viewStatsRows (H.text "Today") (Run.filterToday now runs)
                        , viewStatsRows (H.text "All-time") runs
                        ]

                _ ->
                    viewStatsRows (H.text "This session") (Run.filterBetween qs runs)
            )
        ]


viewStatsRows : H.Html msg -> List Run -> List (H.Html msg)
viewStatsRows title runs =
    [ H.tr []
        [ H.th [ A.class "title" ] [ title ]
        , H.td [ A.colspan 10, A.class "maps-completed" ] [ H.text <| toString (List.length runs) ++ pluralize " map" " maps" (List.length runs) ++ " completed" ]
        ]
    , H.tr []
        ([ H.td [] []
         , H.td [] [ H.text "Average time per map" ]
         ]
            ++ viewDurationSet (Run.meanDurationSet runs)
        )
    , H.tr []
        ([ H.td [] []
         , H.td [] [ H.text "Total time" ]
         ]
            ++ viewDurationSet (Run.totalDurationSet runs)
        )
    ]



--[ H.div []
--    [ H.text <|
--    , viewStatsDurations (Run.totalDurationSet runs)
--    , viewStatsDurations (Run.meanDurationSet runs)
--    ]
--]


viewStatsDurations : Run.DurationSet -> H.Html msg
viewStatsDurations =
    H.text << toString


viewPaginator : Route.HistoryParams -> Int -> H.Html msg
viewPaginator ({ page } as ps) numItems =
    let
        firstVisItem =
            clamp 1 numItems <| (page * perPage) + 1

        lastVisItem =
            clamp 1 numItems <| (page + 1) * perPage

        prev =
            page - 1

        next =
            page + 1

        last =
            numPages numItems - 1

        href i =
            Route.href <| Route.History { ps | page = i }

        ( firstLink, prevLink ) =
            if page /= 0 then
                ( H.a [ href 0 ], H.a [ href prev ] )
            else
                ( H.span [], H.span [] )

        ( nextLink, lastLink ) =
            if page /= last then
                ( H.a [ href next ], H.a [ href last ] )
            else
                ( H.span [], H.span [] )
    in
        H.div [ A.class "paginator" ]
            [ firstLink [ Icon.fas "fast-backward", H.text " First" ]
            , prevLink [ Icon.fas "step-backward", H.text " Prev" ]
            , H.span [] [ H.text <| toString firstVisItem ++ " - " ++ toString lastVisItem ++ " of " ++ toString numItems ]
            , nextLink [ H.text "Next ", Icon.fas "step-forward" ]
            , lastLink [ H.text "Last ", Icon.fas "fast-forward" ]
            ]


viewHistoryTable : Route.HistoryParams -> List Run -> Model -> H.Html msg
viewHistoryTable ({ page } as params) queryRuns model =
    let
        paginator =
            viewPaginator params (List.length queryRuns)

        pageRuns =
            queryRuns
                |> List.drop (page * perPage)
                |> List.take perPage

        goalDuration =
            Run.goalDuration (Run.parseGoalDuration params.goal)
                { session =
                    (case params.after of
                        Just _ ->
                            queryRuns

                        Nothing ->
                            Run.filterToday model.now model.mapwatch.runs
                    )
                , allTime = model.mapwatch.runs
                }
    in
        H.table [ A.class "history" ]
            [ H.thead []
                [ H.tr [] [ H.td [ A.colspan 11 ] [ paginator ] ]

                -- , viewHistoryHeader (Run.parseSort params.sort) params
                ]
            , H.tbody [] (pageRuns |> List.map (viewHistoryRun { showDate = True } params goalDuration) |> List.concat)
            , H.tfoot [] [ H.tr [] [ H.td [ A.colspan 11 ] [ paginator ] ] ]
            ]


viewSortLink : Run.SortField -> ( Run.SortField, Run.SortDir ) -> Route.HistoryParams -> H.Html msg
viewSortLink thisField ( sortedField, dir ) qs =
    let
        ( icon, slug ) =
            if thisField == sortedField then
                -- already sorted on this field, link changes direction
                ( Icon.fas
                    (if dir == Run.Asc then
                        "sort-up"
                     else
                        "sort-down"
                    )
                , Run.stringifySort thisField <| Just <| Run.reverseSort dir
                )
            else
                -- link sorts by this field with default direction
                ( Icon.fas "sort", Run.stringifySort thisField Nothing )
    in
        H.a [ Route.href <| Route.History { qs | sort = Just slug } ] [ icon ]


viewHistoryHeader : ( Run.SortField, Run.SortDir ) -> Route.HistoryParams -> H.Html msg
viewHistoryHeader sort qs =
    let
        link field =
            viewSortLink field sort qs
    in
        H.tr []
            [ H.th [] [ link Run.SortDate ]
            , H.th [ A.class "zone" ] [ link Run.Name ]
            , H.th [] [ link Run.TimeTotal ]
            , H.th [] []
            , H.th [] [ link Run.TimeMap ]
            , H.th [] []
            , H.th [] [ link Run.TimeTown ]
            , H.th [] []
            , H.th [] [ link Run.TimeSide ]
            , H.th [] [ link Run.Portals ]
            , H.th [] []
            ]


viewDuration =
    H.text << formatDuration


type alias HistoryRowConfig =
    { showDate : Bool }


viewHistoryRun : HistoryRowConfig -> Route.HistoryParams -> (Run -> Maybe Time.Time) -> Run -> List (H.Html msg)
viewHistoryRun config qs goals r =
    viewHistoryMainRow config qs (goals r) r :: (List.map (uncurry <| viewHistorySideAreaRow config qs) (Run.durationPerSideArea r))


viewDurationSet : Run.DurationSet -> List (H.Html msg)
viewDurationSet d =
    [ H.td [ A.class "dur total-dur" ] [ viewDuration d.all ] ] ++ viewDurationTail d


viewGoalDurationSet : Maybe Time.Time -> Run.DurationSet -> List (H.Html msg)
viewGoalDurationSet goal d =
    [ H.td [ A.class "dur total-dur" ] [ viewDuration d.all ]
    , H.td [ A.class "dur delta-dur" ] [ viewDurationDelta (Just d.all) goal ]
    ]
        ++ viewDurationTail d


viewDurationTail : Run.DurationSet -> List (H.Html msg)
viewDurationTail d =
    [ H.td [ A.class "dur" ] [ H.text " = " ]
    , H.td [ A.class "dur" ] [ viewDuration d.mainMap, H.text " in map " ]
    , H.td [ A.class "dur" ] [ H.text " + " ]
    , H.td [ A.class "dur" ] [ viewDuration d.town, H.text " in town " ]
    ]
        ++ (if d.sides > 0 then
                [ H.td [ A.class "dur" ] [ H.text " + " ]
                , H.td [ A.class "dur" ] [ viewDuration d.sides, H.text " in sides" ]
                ]
            else
                [ H.td [ A.class "dur" ] [], H.td [ A.class "dur" ] [] ]
           )
        ++ [ H.td [ A.class "portals" ] [ H.text <| toString (roundToPlaces 2 d.portals) ++ pluralize " portal" " portals" d.portals ]
           , H.td [ A.class "town-pct" ]
                [ H.text <| toString (clamp 0 100 <| floor <| 100 * (d.town / (max 1 d.all))) ++ "% in town" ]
           ]


viewHistoryMainRow : HistoryRowConfig -> Route.HistoryParams -> Maybe Time.Time -> Run -> H.Html msg
viewHistoryMainRow { showDate } qs goal r =
    let
        d =
            Run.durationSet r
    in
        H.tr [ A.class "main-area" ]
            ((if showDate then
                [ H.td [ A.class "date" ] [ viewDate r.last.leftAt ] ]
              else
                []
             )
                ++ [ H.td [ A.class "zone" ] [ viewInstance qs r.first.instance ]
                   ]
                ++ viewGoalDurationSet goal d
            )


viewHistorySideAreaRow : HistoryRowConfig -> Route.HistoryParams -> Instance.Address -> Time.Time -> H.Html msg
viewHistorySideAreaRow { showDate } qs instance d =
    H.tr [ A.class "side-area" ]
        ((if showDate then
            [ H.td [ A.class "date" ] [] ]
          else
            []
         )
            ++ [ H.td [] []
               , H.td [ A.class "zone", A.colspan 7 ] [ viewSideAreaName qs (Instance.Instance instance) ]
               , H.td [ A.class "side-dur" ] [ viewDuration d ]
               , H.td [ A.class "portals" ] []
               , H.td [ A.class "town-pct" ] []
               ]
        )


viewDurationDelta : Maybe Time.Time -> Maybe Time.Time -> H.Html msg
viewDurationDelta cur goal =
    case ( cur, goal ) of
        ( Just cur, Just goal ) ->
            let
                dt =
                    cur - goal

                sign =
                    if dt >= 0 then
                        "+"
                    else
                        ""
            in
                H.span [] [ H.text <| " (" ++ sign ++ formatDuration dt ++ ")" ]

        _ ->
            H.span [] []


formatMaybeDuration : Maybe Time.Time -> String
formatMaybeDuration =
    Maybe.Extra.unwrap "--:--" formatDuration
