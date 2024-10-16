# -----------------------------------------------------------------------------------
#				REQUIRE MODULE
#------------------------------------------------------------------------------------
require Logger
Logger.configure(level: :info)
#------------------------------ THE END ---------------------------------------------


# -----------------------------------------------------------------------------------
#				MODULE FUNCTION
# -----------------------------------------------------------------------------------
defmodule BaselineCamera do
  use Membrane.Pipeline  

  @impl true
  def handle_init(_ctx, _opts) do
    baselinelogo_path = "/home/ubuntu/baseline_camera/lib/img/Baseline_Logo.png"
    sponsorlogo_path = "/home/ubuntu/baseline_camera/lib/img/Sponsor_Logo.png"
    if File.exists?(baselinelogo_path) and File.exists?(sponsorlogo_path) do
      Logger.info("Overlay images found")
    else
      Logger.error("Overlay images not found")
    end

#    ytb_rtmp = "rtmp://a.rtmp.youtube.com/live2/0wbk-xhgj-x73m-cgjb-dw08"
#    fb_rtmp = "rtmps://live-api-s.facebook.com:443/rtmp/FB-2286586258359601-0-AbzqjOP8KwA0BeMa"
#    app_rtmp = "rtmp://stream.baseline.vn/live/camera"
    home_rtmp = "rtmp://192.168.40.4:1940/54962f7d-22f9-4bfd-a120-13c4ffa1a124.stream"

    # Video input: USB Camera path
    usbcamera_name = "/dev/video0"

    # Audio input: 0 (Internal micro onboard) or 4 (External micro over USB)
    card_name = 0

    # RTMP links
    links = home_rtmp

    # Starting call api to obtain info of match data
    spawn(fn -> poll_url() end)

    # Initialize raw video from USB Camera
    rawvideo =
      child(:video_source,
        %Membrane.CameraCapture{
          device: usbcamera_name,
          framerate: 5
        }
      )
      |> child(:video_converter, %Membrane.FFmpeg.SWScale.PixelFormatConverter{format: :I420})
      |> child(:display_baselinelogo, %Membrane.OverlayFilter{initial_overlay: %Membrane.OverlayFilter.OverlayDescription{blend_mode: :over, overlay: baselinelogo_path, x: :right, y: :top}})
      |> child(:display_sponsorlogo, %Membrane.OverlayFilter{initial_overlay: %Membrane.OverlayFilter.OverlayDescription{blend_mode: :over, overlay: sponsorlogo_path, x: :left, y: :top}})
      |> child(:video_encoder, %Membrane.H264.FFmpeg.Encoder{profile: :baseline, preset: :ultrafast, tune: :zerolatency})
      |> child(:video_payloader, %Membrane.H264.Parser{output_stream_structure: :avc1, generate_best_effort_timestamps: %{framerate: {25, 1}}})
      |> child(:video_realtimer, Membrane.Realtimer)

    Logger.info("Video source initialized")

    # Initialize raw audio from USB Micro
    rawaudio =
      child(:audio_source,
        %Membrane.PortAudio.Source{ 
          device_id: card_name,
          channels: 1,

          sample_format: :s16le,
          sample_rate: 44100,
          latency: :high
        }
      )
      |> child(:audio_encoder, %Membrane.AAC.FDK.Encoder{aot: :mpeg4_lc, bitrate: 128000, bitrate_mode: 5})
      |> child(:audio_parser, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
      |> child(:audio_realtimer, Membrane.Realtimer)

    Logger.info("Audio source initialized")

    # Initialize RTMP link to livestreams
    rtmp_link =
      child(:rtmp_sink,
        %Membrane.RTMP.Sink{
          rtmp_url: links,
          max_attempts: :infinity
        }
      )

    Logger.info("RTMP sender initialized") 

    # Specifications 
    spec = [
      rawvideo
      |> via_in(Pad.ref(:video, 0), toilet_capacity: 2000)
      |> get_child(:rtmp_sink),

      rawaudio
      |> via_in(Pad.ref(:audio, 0), toilet_capacity: 2000)
      |> get_child(:rtmp_sink),

      rtmp_link
    ]

    {[spec: spec], streams_to_end: 2}
  end

  def get_match_data do
    url = "https://dev.baseline.vn/api/v2/matches/da4a6b59-2026-49c6-b0fe-8989c68a5f31?expand=team1%2Cteam2 "
    headers = [
      {"User-Agent", "Dart/3.5 (dart:io)"},
      {"Accept", "application/json"},
      {"Accept-Encoding", "gzip"},
      {"Authorization", "Bearer LzYekvdXLwz6FF5W6UVXou2X"},
      {"Content-Type", "application/json"},
      {"Session", "df2f03cd-1abc-488f-aa9e-60860a985944"},
      {"Cookie", "session_token=eyJfcmFpbHMiOnsibWVzc2FnZSI6IklqRTRNbU16WWpkakxUVmpNVGt0TkdGak9DMDRPR1poTFRBd01EQTVaalJsWmpJeFpDST0iLCJleHAiOiIyMDQ0LTA4LTAzVDAxOjU2OjU5Ljk5NloiLCJwdXIiOiJjb29raWUuc2Vzc2lvbl90b2tlbiJ9fQ%3D%3D--845e3846431ff43c322f23d5a17d6059aa103193"}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body, headers: resp_headers}} ->
        decoded_body = decode_body(body, resp_headers)
        case Jason.decode(decoded_body) do
          {:ok, json} ->
            Logger.info("Callling successful baseline url")
            {:ok, json}

          {:error, reason} ->
            Logger.error("Failed to parse JSON: #{inspect(reason)}")
            {:error, "JSON parsing failed"}
        end 

      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        Logger.error("Request failed with status code: #{status_code}")
        {:error, "Request failed with status code: #{status_code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Request failed: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp decode_body(body, headers) do
    content_encoding = Enum.find_value(headers, fn {k, v} -> 
      if String.downcase(k) == "content-encoding", do: v
    end)

    case content_encoding do
      "gzip" -> :zlib.gunzip(body)
      _ -> body
    end
  end

  defp poll_url() do
    case get_match_data() do
      {:ok, data} ->
        team1_name = get_in(data, ["team1", "name"])
        team2_name = get_in(data, ["team2", "name"])
        match_info = "#{team1_name} vs #{team2_name}"
        Logger.info("Match: #{match_info}")

        # Process the data here. For now, we'll just log it
        Logger.info("Received match data: #{inspect(data)}")

      {:error, reason} ->
        Logger.error("Failed to get match data: #{inspect(reason)}")
    end

    # Wait for 60 seconds before the next call
#    Process.sleep(30_000)
#    poll_url()
  end

#  @impl true
#  def handle_info(msg, state) do
#    Logger.warn("Received unexpected message: #{inspect(msg)}")
#    {[], state}
#  end

#  @impl true
#  def handle_notification({:draw_updated, new_info}, :draw, _ctx, state) do
#    Logger.info("Draw element updated with: #{new_info}")
#    {[], state}
#  end

#  @impl true
#  def handle_child_notification({:error, :rtmp_sink, reason}, _child, _ctx, state) do
#    Logger.error("RTMP sink error: #{inspect(reason)}")
#    {{:stop, {:rtmp_error, reason}}, state}
#  end

  @impl true
  def handle_child_notification({:error, reason}, child, _context, state) do
    Logger.error("Error in #{inspect(child)}: #{inspect(reason)}")
    {{:stop, reason}, state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _context, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:rtmp_sink, _pad, _ctx, %{stream_to_end: 1} = state) do
    Membrane.Pipeline.terminate(self())
    {[], %{state | streams_to_end: 0}}
  end

  @impl true
  def handle_element_end_of_stream(:rtmp_sink, _pad, _ctx, state) do
    {[], %{state | streams_to_end: 1}}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end
end
#------------------------------ THE END ---------------------------------------------


#------------------------------------------------------------------------------------
#				MAIN FUNCTION
# -----------------------------------------------------------------------------------
# Check and display available audio list 
Membrane.PortAudio.print_devices()

# On CI we just check if the script compiles
if System.get_env("CI") == "true" do # On CI we just check if the script compiles
  Logger.info("CI=true, exiting")
  exit(:normal)
end
Process.register(self(), :script)

# Initialize Hackney
:application.ensure_all_started(:hackney)

# Run Application
Logger.info("Starting the pipeline")
{:ok, _supervisor, _pipeline} = Membrane.Pipeline.start_link(BaselineCamera)

Process.sleep(:infinity)
#------------------------------ THE END ---------------------------------------------

