class Log < ArvadosModel
  include HasUuid
  include KindAndEtag
  include CommonApiTemplate
  serialize :properties, Hash
  before_validation :set_default_event_at
  attr_accessor :object, :object_kind
  after_save :send_notify

  api_accessible :user, extend: :common do |t|
    t.add :id
    t.add :object_uuid
    t.add :object_owner_uuid
    t.add :object_kind
    t.add :event_at
    t.add :event_type
    t.add :summary
    t.add :properties
  end

  def object_kind
    if k = ArvadosModel::resource_class_for_uuid(object_uuid)
      k.kind
    end
  end

  def fill_object(thing)
    self.object_uuid ||= thing.uuid
    if respond_to? :object_owner_uuid=
      # Skip this if the object_owner_uuid migration hasn't happened
      # yet, i.e., we're in the process of migrating an old database.
      self.object_owner_uuid = thing.owner_uuid
    end
    self.summary ||= "#{self.event_type} of #{thing.uuid}"
    self
  end

  def fill_properties(age, etag_prop, attrs_prop)
    self.properties.merge!({"#{age}_etag" => etag_prop,
                             "#{age}_attributes" => attrs_prop})
  end

  def update_to(thing)
    fill_properties('new', thing.andand.etag, thing.andand.logged_attributes)
    case event_type
    when "create"
      self.event_at = thing.created_at
    when "update"
      self.event_at = thing.modified_at
    when "destroy"
      self.event_at = db_current_time
    end
    self
  end

  def self.readable_by(*users_list)
    if users_list.select { |u| u.is_admin }.any?
      return self
    end
    user_uuids = users_list.map { |u| u.uuid }
    uuid_list = user_uuids + users_list.flat_map { |u| u.groups_i_can(:read) }
    uuid_list.uniq!
    permitted = "(SELECT head_uuid FROM links WHERE link_class='permission' AND tail_uuid IN (:uuids))"
    joins("LEFT JOIN container_requests ON container_requests.container_uuid=logs.object_uuid").
      where("logs.object_uuid IN #{permitted} OR "+
            "container_requests.uuid IN (:uuids) OR "+
            "container_requests.owner_uuid IN (:uuids) OR "+
            "logs.object_uuid IN (:uuids) OR "+
            "logs.owner_uuid IN (:uuids) OR "+
            "logs.object_owner_uuid IN (:uuids)",
            uuids: uuid_list)
  end

  protected

  def permission_to_create
    true
  end

  def permission_to_update
    current_user.andand.is_admin
  end

  alias_method :permission_to_delete, :permission_to_update

  def set_default_event_at
    self.event_at ||= db_current_time
  end

  def log_start_state
    # don't log start state on logs
  end

  def log_change(event_type)
    # Don't log changes to logs.
  end

  def ensure_valid_uuids
    # logs can have references to deleted objects
  end

  def send_notify
    connection.execute "NOTIFY logs, '#{self.id}'"
  end

end
