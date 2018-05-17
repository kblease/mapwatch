module Main exposing (main)

import Date
import Regex
import Ports
import Html as H
import Html.Attributes as A
import Html.Events as E


main =
    H.programWithFlags
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }


type alias Flags =
    { wshost : String
    }


type alias Model =
    { parsedLines : List ParsedLogLine
    , lines : List LogLine
    , config : Ports.Config
    , entries : List InstanceEntry
    }


type Msg
    = StartWatching
    | InputClientLogPath String
    | RecvLogLine String


type alias LogLine =
    { raw : String
    , date : Date.Date
    , info : LogInfo
    }


type alias ParsedLogLine =
    Result { raw : String, err : String } LogLine


type LogInfo
    = Opening
    | ConnectingToInstanceServer String
    | YouHaveEntered String


type InstanceEntry
    = InstanceEntry { zone : String, addr : String, at : Date.Date }
    | OpenedEntry { at : Date.Date }


regexParseFirst : String -> String -> Maybe Regex.Match
regexParseFirst regex txt =
    txt
        |> Regex.find (Regex.AtMost 1) (Regex.regex regex)
        |> List.head


regexParseFirstRes : String -> err -> String -> Result err Regex.Match
regexParseFirstRes regex err txt =
    regexParseFirst regex txt |> Result.fromMaybe err


parseLogInfo : String -> Maybe LogInfo
parseLogInfo raw =
    let
        parseOpening =
            case regexParseFirst "LOG FILE OPENING" raw of
                Just _ ->
                    Just Opening

                _ ->
                    Nothing

        parseEntered =
            case regexParseFirst "You have entered (.*)\\.$" raw |> Maybe.map .submatches of
                Just [ Just zone ] ->
                    Just <| YouHaveEntered zone

                _ ->
                    Nothing

        parseConnecting =
            case regexParseFirst "Connecting to instance server at (.*)$" raw |> Maybe.map .submatches of
                Just [ Just addr ] ->
                    Just <| ConnectingToInstanceServer addr

                _ ->
                    Nothing
    in
        [ parseOpening, parseEntered, parseConnecting ]
            -- use the first matching parser
            |> List.map (Maybe.withDefault [] << Maybe.map List.singleton)
            |> List.concat
            |> List.head


parseLogLine : String -> ParsedLogLine
parseLogLine raw =
    let
        date : Result String Date.Date
        date =
            raw
                -- rearrange the date so the built-in js parser likes it
                |> regexParseFirstRes "\\d{4}/\\d{2}/\\d{2} \\d{2}:\\d{2}:\\d{2}" "no date in logline"
                |> Result.map (Regex.split Regex.All (Regex.regex "[/: ]") << .match)
                |> Result.andThen
                    (\strs ->
                        case strs of
                            [ yr, mo, d, h, mn, s ] ->
                                Date.fromString <| (String.join "-" [ yr, mo, d ]) ++ "T" ++ (String.join ":" [ h, mn, s ]) ++ "Z"

                            _ ->
                                Err ("date parsed-count mismatch: " ++ toString strs)
                    )

        result d i =
            { raw = raw
            , date = d
            , info = i
            }

        info =
            parseLogInfo raw
                |> Result.fromMaybe "logline not recognized"

        error err =
            { err = err, raw = raw }
    in
        Result.map2 result date info
            |> Result.mapError error


initModel : Flags -> Model
initModel flags =
    { parsedLines = []
    , lines = []
    , entries = []
    , config =
        { wshost = flags.wshost
        , clientLogPath = "../Client.txt"
        }
    }


init flags =
    initModel flags
        |> update StartWatching


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        StartWatching ->
            ( model, Ports.startWatching model.config )

        InputClientLogPath path ->
            let
                config =
                    model.config
            in
                ( { model | config = { config | clientLogPath = path } }, Cmd.none )

        RecvLogLine raw ->
            let
                updateLogLines model =
                    let
                        parsedLine =
                            parseLogLine raw
                    in
                        (case parsedLine of
                            Ok line ->
                                { model | lines = line :: model.lines }

                            _ ->
                                model
                        )
                            |> (\m -> { m | parsedLines = parsedLine :: model.parsedLines })
            in
                model
                    |> updateLogLines
                    |> updateInstanceEntries
                    |> \m -> ( m, Cmd.none )


updateInstanceEntries : Model -> Model
updateInstanceEntries model =
    case List.head model.lines of
        Nothing ->
            model

        Just first ->
            case model.lines |> List.take 2 |> List.map .info of
                (ConnectingToInstanceServer addr) :: (YouHaveEntered zone) :: _ ->
                    { model | entries = InstanceEntry { zone = zone, addr = addr, at = first.date } :: model.entries }

                Opening :: _ ->
                    { model | entries = OpenedEntry { at = first.date } :: model.entries }

                _ ->
                    model


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Ports.logline RecvLogLine
        ]


viewLogLine : ParsedLogLine -> H.Html msg
viewLogLine mline =
    H.li []
        (case mline of
            Ok line ->
                [ H.text (toString line.date)
                , H.text (toString line.info)
                , H.div [] [ H.i [] [ H.text line.raw ] ]
                ]

            Err { raw, err } ->
                [ H.text "PARSE ERROR: "
                , H.text err
                , H.div [] [ H.i [] [ H.text raw ] ]
                ]
        )


viewInstanceEntry : InstanceEntry -> H.Html msg
viewInstanceEntry entry =
    case entry of
        InstanceEntry entry ->
            H.li [] [ H.text <| toString entry.at ++ ": " ++ entry.zone ++ "@" ++ entry.addr ]

        OpenedEntry entry ->
            H.li [] [ H.text <| toString entry.at ++ ": game reopened" ]


viewConfig : Model -> H.Html Msg
viewConfig model =
    H.form [ E.onSubmit StartWatching ]
        [ H.div []
            [ H.text "local log server: "
            , H.input [ A.disabled True, A.type_ "text", A.value model.config.wshost ] []
            ]
        , H.div []
            [ H.text "path to PoE Client.txt: "
            , H.input [ A.type_ "text", E.onInput InputClientLogPath, A.value model.config.clientLogPath ] []
            ]
        , H.div [] [ H.button [ A.type_ "submit" ] [ H.text "Watch" ] ]
        ]


view : Model -> H.Html Msg
view model =
    H.div []
        [ H.text "Hello elm-world!"
        , viewConfig model
        , H.text "instance-entries:"
        , H.ul [] (List.map viewInstanceEntry model.entries)
        , H.text "parsed loglines:"
        , H.ul [] (List.map viewLogLine model.parsedLines)
        ]
