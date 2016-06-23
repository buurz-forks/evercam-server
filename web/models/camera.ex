defmodule Camera do
  use EvercamMedia.Web, :model
  import Ecto.Changeset
  import Ecto.Query
  alias EvercamMedia.Repo
  alias EvercamMedia.Schedule
  alias EvercamMedia.Util

  @required_fields ~w(exid name owner_id config is_public is_online_email_owner_notification)
  @optional_fields ~w(timezone thumbnail_url is_online last_polled_at last_online_at updated_at created_at)

  schema "cameras" do
    belongs_to :owner, User, foreign_key: :owner_id
    belongs_to :vendor_model, VendorModel, foreign_key: :model_id
    has_many :access_rights, AccessRight
    has_many :shares, CameraShare
    has_many :snapshots, Snapshot
    has_one :cloud_recordings, CloudRecording
    has_one :motion_detections, MotionDetection

    field :exid, :string
    field :name, :string
    field :timezone, :string
    field :thumbnail_url, :string
    field :is_online, :boolean
    field :is_public, :boolean
    field :is_online_email_owner_notification, :boolean, default: false
    field :discoverable, :boolean, default: false
    field :config, EvercamMedia.Types.JSON
    field :mac_address, EvercamMedia.Types.MACADDR
    field :location, Geo.Point
    field :last_polled_at, Ecto.DateTime, default: Ecto.DateTime.utc
    field :last_online_at, Ecto.DateTime, default: Ecto.DateTime.utc
    timestamps(inserted_at: :created_at, type: Ecto.DateTime, default: Ecto.DateTime.utc)
  end

  def all do
    Camera
    |> join(:full, [c], vm in assoc(c, :vendor_model))
    |> join(:full, [c, vm], v in assoc(vm, :vendor))
    |> preload(:cloud_recordings)
    |> preload(:motion_detections)
    |> preload(:vendor_model)
    |> preload([vendor_model: :vendor])
    |> Repo.all
  end

  def invalidate_user(%User{} = user) do
    ConCache.delete(:cameras, "#{user.username}_true")
    ConCache.delete(:cameras, "#{user.username}_false")
  end

  def invalidate_camera(%Camera{} = camera) do
    ConCache.delete(:camera_full, camera.exid)
    CameraShare
    |> where(camera_id: ^camera.id)
    |> preload(:user)
    |> Repo.all
    |> Enum.map(fn(cs) -> cs.user end)
    |> Enum.into([camera.owner])
    |> Enum.each(fn(user) -> invalidate_user(user) end)
  end

  def for(user, include_shared? \\ true) do
    case include_shared? do
      true -> owned_by(user) |> Enum.into(shared_with(user))
      false -> owned_by(user)
    end
  end

  def owned_by(user) do
    token = AccessToken.active_token_for(user.id)
    access_rights_query = AccessRight |> where([ar], ar.token_id == ^token.id)

    Camera
    |> where([cam], cam.owner_id == ^user.id)
    |> preload(:owner)
    |> preload(access_rights: ^access_rights_query)
    |> preload([access_rights: :access_token])
    |> preload(:vendor_model)
    |> preload([vendor_model: :vendor])
    |> preload(:cloud_recordings)
    |> Repo.all
  end

  def shared_with(user) do
    token = AccessToken.active_token_for(user.id)
    access_rights_query = AccessRight |> where([ar], ar.token_id == ^token.id)

    Camera
    |> join(:left, [u], cs in CameraShare)
    |> where([cam, cs], cs.user_id == ^user.id)
    |> where([cam, cs], cam.id == cs.camera_id)
    |> preload(:owner)
    |> preload(access_rights: ^access_rights_query)
    |> preload([access_rights: :access_token])
    |> preload(:vendor_model)
    |> preload([vendor_model: :vendor])
    |> preload(:cloud_recordings)
    |> Repo.all
  end

  def get(exid) do
    ConCache.dirty_get_or_store(:camera, exid, fn() ->
      Camera.by_exid(exid)
    end)
  end

  def get_full(exid) do
    ConCache.dirty_get_or_store(:camera_full, exid, fn() ->
      Camera.by_exid_with_associations(exid)
    end)
  end

  def by_exid(exid) do
    Camera
    |> where(exid: ^exid)
    |> Repo.one
  end

  def by_exid_with_associations(exid) do
    Camera
    |> where([cam], cam.exid == ^exid)
    |> preload(:cloud_recordings)
    |> preload(:motion_detections)
    |> preload(:owner)
    |> preload(:vendor_model)
    |> preload([vendor_model: :vendor])
    |> preload(:access_rights)
    |> preload([access_rights: :access_token])
    |> Repo.one
  end

  def auth(camera) do
    username(camera) <> ":" <> password(camera)
  end

  def username(camera) do
    "#{camera.config["auth"]["basic"]["username"]}"
  end

  def password(camera) do
    "#{camera.config["auth"]["basic"]["password"]}"
  end

  def snapshot_url(camera, type \\ "jpg") do
    cond do
      external_url(camera) != "" && res_url(camera, type) != "" ->
        "#{external_url(camera)}#{res_url(camera, type)}"
      external_url(camera) != "" ->
        "#{external_url(camera)}"
      true ->
        ""
    end
  end

  def external_url(camera, protocol \\ "http") do
    host = host(camera) |> to_string
    port = port(camera, "external", protocol) |> to_string
    case {host, port} do
      {"", _} -> ""
      {host, ""} -> "#{protocol}://#{host}"
      {host, port} -> "#{protocol}://#{host}:#{port}"
    end
  end

  def res_url(camera, type \\ "jpg") do
    url = "#{camera.config["snapshots"][type]}"
    case String.starts_with?(url, "/") || String.length(url) == 0 do
      true -> "#{url}"
      false -> "/#{url}"
    end
  end

  defp url_path(camera, type) do
    cond do
      res_url(camera, type) != "" ->
        res_url(camera, type)
      res_url(camera, type) == "" && get_model_attr(camera, :config) != "" ->
        res_url(camera.vendor_model, type)
      true ->
        ""
    end
  end

  def host(camera, network \\ "external") do
    camera.config["#{network}_host"]
  end

  def port(camera, network, protocol) do
    camera.config["#{network}_#{protocol}_port"]
  end

  def rtsp_url(camera, network \\ "external", type \\ "h264", include_auth \\ true) do
    auth = if include_auth, do: "#{auth(camera)}@", else: ""
    path = url_path(camera, type)
    host = host(camera)
    port = port(camera, network, "rtsp")

    case path != "" && host != "" && "#{port}" != "" && "#{port}" != 0 do
      true -> "rtsp://#{auth}#{host}:#{port}#{path}"
      false -> ""
    end
  end

  def get_rtmp_url(camera) do
    if rtsp_url(camera) != "" do
      base_url = EvercamMedia.Endpoint.url |> String.replace("http", "rtmp") |> String.replace("4000", "1935")
      base_url <> "/live/" <> streaming_token(camera) <> "?camera_id=" <> camera.exid
    else
      ""
    end
  end

  def get_hls_url(camera) do
    if rtsp_url(camera) != "" do
      base_url = EvercamMedia.Endpoint.url
      base_url <> "/live/" <> streaming_token(camera) <> "/index.m3u8?camera_id=" <> camera.exid
    else
      ""
    end
  end

  defp streaming_token(camera) do
    token = username(camera) <> "|" <> password(camera) <> "|" <> rtsp_url(camera)
    Util.encode([token])
  end

  def get_vendor_attr(camera_full, attr) do
    case camera_full.vendor_model do
      nil -> ""
      vendor_model -> Map.get(vendor_model.vendor, attr)
    end
  end

  def get_model_attr(camera_full, attr) do
    case camera_full.vendor_model do
      nil -> ""
      vendor_model -> Map.get(vendor_model, attr)
    end
  end

  def get_timezone(camera) do
    case camera.timezone do
      nil -> "Etc/UTC"
      timezone -> timezone
    end
  end

  def get_offset(camera) do
    camera
    |> Camera.get_timezone
    |> Calendar.DateTime.now!
    |> Calendar.Strftime.strftime!("%z")
  end

  def get_mac_address(camera) do
    case camera.mac_address do
      nil -> ""
      mac_address -> mac_address
    end
  end

  def get_location(camera) do
    {lng, lat} =
      case camera.location do
        %Geo.Point{} -> camera.location.coordinates
        _nil -> {0, 0}
      end
    %{lng: lng, lat: lat}
  end

  def get_camera_info(exid) do
    camera = Camera.get(exid)
    %{
      "url" => external_url(camera),
      "auth" => auth(camera)
    }
  end

  def get_rights(camera, user) do
    cond do
      is_owner?(user, camera) ->
        "snapshot,list,edit,delete,view,grant~snapshot,grant~view,grant~edit,grant~delete,grant~list"
      camera.access_rights == [] ->
        "snapshot,list"
      true ->
        camera.access_rights
        |> Enum.filter(fn(ar) -> ar.access_token.user_id == user.id end)
        |> Enum.map(fn(ar) -> ar.right end)
        |> Enum.into(["snapshot", "list"])
        |> Enum.uniq
        |> Enum.join(",")
    end
  end

  def is_owner?(nil, _camera), do: false
  def is_owner?(user, camera) do
    user.id == camera.owner_id
  end

  def recording?(camera_full) do
    !!Application.get_env(:evercam_media, :start_camera_workers)
    && CloudRecording.sleep(camera_full.cloud_recordings) == 1000
    && Schedule.scheduled_now?(camera_full) == {:ok, true}
  end

  def delete_by_owner(owner_id) do
    Camera
    |> where([cam], cam.owner_id == ^owner_id)
    |> Repo.delete_all
  end

  def changeset(camera, params \\ :invalid) do
    camera
    |> cast(params, @required_fields, @optional_fields)
    |> unique_constraint(:exid, [name: "cameras_exid_index"])
  end
end
