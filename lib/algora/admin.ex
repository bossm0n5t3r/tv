import Ecto.Query, warn: false
import Ecto.Changeset
alias Algora.{Accounts, Library, Storage, Repo}
alias Algora.Library.Video

defmodule Algora.Admin do
  @tracks %{
    manifest: "index.m3u8",
    audio: "g3cFYXVkaW8.m3u8",
    video: "g3cFdmlkZW8.m3u8"
  }

  defp get(url) do
    Finch.build(:get, url) |> Finch.request(Algora.Finch)
  end

  def get_playlist(video) do
    {:ok, resp} = get(video.url)
    {:ok, playlist} = ExM3U8.deserialize_playlist(resp.body, [])
    playlist
  end

  def get_media_playlist(video, uri) do
    url = "#{video.url_root}/#{uri}"

    with {:ok, resp} <- get(url),
         {:ok, playlist} <- ExM3U8.deserialize_media_playlist(resp.body, []) do
      playlist
    else
      _ -> nil
    end
  end

  def get_media_playlists(video) do
    %{
      video: get_media_playlist(video, @tracks.video),
      audio: get_media_playlist(video, @tracks.audio)
    }
  end

  def set_thumbnail!(id, path) do
    video = Library.get_video!(id)
    {:ok, _} = Library.store_thumbnail_from_file(video, path || "/tmp/#{id}.png")
    {:ok, _} = Library.store_og_image_from_file(video, path || "/tmp/#{id}.png")
  end

  def set_title!(id, title) do
    video = Library.get_video!(id)
    user = Accounts.get_user!(video.user_id)
    {:ok, _} = Library.update_video(video, %{title: title})
    {:ok, _} = Accounts.update_settings(user, %{channel_tagline: title})
  end

  def pipelines() do
    Node.list() |> Enum.flat_map(&Membrane.Pipeline.list_pipelines/1)
  end

  def broadcasts() do
    pipelines() |> Enum.map(fn pid -> GenServer.call(pid, :get_video_id) end)
  end

  def download_chunks(video, chunks, dir) do
    Task.async_stream(
      Enum.with_index(chunks),
      fn {chunk, i} ->
        IO.puts("#{rounded(100 * i / length(chunks))}%")

        dl_path = "#{dir}/#{chunk}"

        if not File.exists?(dl_path) do
          {:ok, :saved_to_file} =
            :httpc.request(:get, {~c"#{video.url_root}/#{chunk}", []}, [],
              stream: ~c"#{dl_path}.part"
            )

          File.rename!("#{dl_path}.part", dl_path)
        end
      end,
      max_concurrency: 100,
      timeout: :infinity
    )
    |> Stream.map(fn {:ok, val} -> val end)
    |> Enum.to_list()
  end

  def download_video(video, dir) do
    playlists = get_media_playlists(video)

    video_chunks =
      for n <- playlists.video.timeline,
          Map.has_key?(n, :uri),
          do: n.uri

    audio_chunks =
      for n <- playlists.audio.timeline,
          Map.has_key?(n, :uri),
          do: n.uri

    {time, _} = :timer.tc(&download_chunks/3, [video, video_chunks ++ audio_chunks, dir])

    video_chunks
    |> Enum.map(fn chunk -> "#{dir}/#{chunk}" end)
    |> concatenate_files("#{dir}/video.mp4")

    audio_chunks
    |> Enum.map(fn chunk -> "#{dir}/#{chunk}" end)
    |> concatenate_files("#{dir}/audio.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-i",
          "#{dir}/video.mp4",
          "-i",
          "#{dir}/audio.mp4",
          "-c",
          "copy",
          "#{dir}/output.mp4"
        ]
      )

    %File.Stat{size: size} = File.stat!("#{dir}/output.mp4")

    IO.puts(
      "Downloaded #{rounded(size / 1_000_000)} MB in #{rounded(time / 1_000_000)} s (#{rounded(size / time)} MB/s)"
    )
  end

  def tmp_dir do
    case Algora.config([:mode]) do
      :prod ->
        "/data"

      _ ->
        "/home/zaf/Downloads"
        # _ -> System.tmp_dir!()
    end
  end

  def download(video) do
    dir = Path.join(tmp_dir(), video.uuid)

    File.mkdir_p!(dir)

    {time, _} = :timer.tc(&download_video/2, [video, dir])

    %File.Stat{size: size} = File.stat!("#{dir}/output.mp4")

    IO.puts("Transmuxed #{rounded(size / 1_000_000)} MB in #{rounded(time / 1_000_000)} s")
  end

  def save_download(video, cb \\ fn _ -> nil end) do
    mp4_basename = Slug.slugify("#{Date.to_string(video.inserted_at)}-#{video.title}")

    mp4_video =
      %Video{
        title: video.title,
        duration: video.duration,
        type: :vod,
        format: :mp4,
        is_live: false,
        visibility: :unlisted,
        user_id: video.user_id,
        transmuxed_from_id: video.id,
        thumbnail_url: video.thumbnail_url
      }
      |> change()
      |> Video.put_video_url(:mp4, mp4_basename)

    %{remote_path: mp4_remote_path} = mp4_video.changes

    mp4_local_path = Path.join([tmp_dir(), video.uuid, "output.mp4"])

    Storage.upload_from_filename(mp4_local_path, mp4_remote_path, cb, content_type: "video/mp4")

    Repo.insert!(mp4_video)
  end

  def concatenate_files(paths, output_file) do
    paths
    |> Stream.map(&stream_file/1)
    |> Stream.concat()
    |> Stream.into(File.stream!(output_file, [:write, :delayed]))
    |> Stream.run()
  end

  defp stream_file(file_path) do
    File.stream!(file_path, [], 2048)
  end

  defp rounded(num), do: Float.round(num, 1)
end
