# name: discourse-topic-previews
# about: A Discourse plugin that gives you a topic preview image in the topic list
# version: 0.1
# authors: Angus McLeod

register_asset 'stylesheets/previews.scss'

after_initialize do

  Category.register_custom_field_type('list_thumbnails', :boolean)
  Category.register_custom_field_type('list_excerpts', :boolean)
  Category.register_custom_field_type('list_actions', :boolean)
  Category.register_custom_field_type('list_category_badge_move', :boolean)
  Topic.register_custom_field_type('thumbnails', :json)

  @nil_thumbs = TopicCustomField.where( name: 'thumbnails', value: nil )
  if @nil_thumbs.length
    @nil_thumbs.each do |thumb|
      hash = { :normal => '', :retina => ''}
      thumb.value = ::JSON.generate(hash)
      thumb.save!
    end
  end

  module ListHelper
    class << self
      def create_thumbnails(id, image, original_url)
        normal = image ? thumbnail_url(image, 230, 147) : original_url
        retina = image ? thumbnail_url(image, 230, 147) : original_url
        thumbnails = { normal: normal, retina: retina }
        save_thumbnails(id, thumbnails)
        return thumbnails
      end

      def thumbnail_url (image, w, h)
        image.create_thumbnail!(w, h) if !image.has_thumbnail?(w, h)
        image.thumbnail(w, h).url
      end

      def save_thumbnails(id, thumbnails)
        return if !thumbnails
        topic = Topic.find(id)
        topic.custom_fields['thumbnails'] = thumbnails
        topic.save_custom_fields
      end
    end
  end

  require 'cooked_post_processor'
  class ::CookedPostProcessor

    def is_a_image_url(url)
      image_last_name = ["jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp", "svg", "webp", "ico"]
      images_regexp = /\.(#{image_last_name.join("|")})$/i
      url =~ images_regexp ? true : false
    end

    def get_linked_image(url)
      max_size = SiteSetting.max_image_size_kb.kilobytes
      file = FileHelper.download(url, max_size, "discourse", true, 10) rescue nil
      filename_last = file.path.split('/')[-1]
      if url =~ /wx_fmt/
        filename = filename_last + "." + url.split("wx_fmt=").last
      elsif is_a_image_url(url)
        filename = filename_last + "." + url.split(".").last  
      else        
        filename = filename_last + ".jpeg"
      end 
      image = file ? Upload.create_for(@post.user_id, file, filename, File.size(file.path)) : nil
      image
    end

    def create_topic_thumbnails(url)
      local = UrlHelper.is_local(url)
      image = local ? Upload.find_by(sha1: url[/[a-z0-9]{40,}/i]) : get_linked_image(url)
      ListHelper.create_thumbnails(@post.topic.id, image, url)
    end

    def is_image_big_enough?(url)
      local = UrlHelper.is_local(url)
      image = local ? Upload.find_by(sha1: url[/[a-z0-9]{40,}/i]) : get_linked_image(url)      
      if local 
        return true 
      else
        if image.height.nil?
          return false
        elsif image.height == 147
          return true
        elsif image.height > 235
          return true
        else
          return false
        end
      end
    end

    def update_topic_image
      if @post.is_first_post? and @post.topic.image_url.nil?
        extract_images = extract_images_for_topic
        if extract_images.size > 1
          #select a pic with height bigger than 235
          begin
            img = extract_images.shift
            next if !img["src"]
            url = img["src"][0...255]         
          end while not is_image_big_enough?(url) and not extract_images.empty?        
          return if !img["src"] or extract_images.empty?
          @post.topic.update_column(:image_url, url)
          create_topic_thumbnails(url)
        elsif extract_images.size == 1
          #select the only pic as thumbnails
          img = extract_images.first
          return if !img["src"]
          url = img["src"][0...255]
          @post.topic.update_column(:image_url, url)
          create_topic_thumbnails(url)
        else
          #no pic to nothing
          return
        end
      end
    end

  end

  require 'topic_list_item_serializer'
  class ::TopicListItemSerializer
    attributes :thumbnails,
               :topic_post_id,
               :topic_post_liked,
               :topic_post_like_count,
               :topic_post_can_like,
               :topic_post_can_unlike,
               :topic_post_bookmarked

    def first_post_id
      Post.find_by(topic_id: object.id, post_number: 1).id
    end

    def topic_post_id
      accepted_id = object.custom_fields["accepted_answer_post_id"].to_i
      return accepted_id > 0 ? accepted_id : first_post_id
    end

    def excerpt
      if object.custom_fields["accepted_answer_post_id"].to_i > 0 || object.excerpt.blank?
        cooked = Post.where(id: topic_post_id).pluck('cooked')
        excerpt = PrettyText.excerpt(cooked[0], 200, keep_emoji_images: true)
      else
        excerpt = object.excerpt
      end
      excerpt.gsub!(/(\[#{I18n.t 'excerpt_image'}\])/, "") if excerpt
      excerpt
    end

    def include_excerpt?
      object.excerpt.present?
    end

    def thumbnails
      return unless object.archetype == Archetype.default
      thumbs = get_thumbnails || get_thumbnails_from_image_url
      thumbs
    end

    def include_thumbnails?
      thumbnails.present? && thumbnails['normal'].present?
    end

    def get_thumbnails
      thumbnails = object.custom_fields['thumbnails']
      if thumbnails.is_a?(String)
        thumbnails = ::JSON.parse(thumbnails)
      end
      if thumbnails.is_a?(Array)
        thumbnails = thumbnails[0]
      end
      thumbnails.is_a?(Hash) ? thumbnails : false
    end

    def get_thumbnails_from_image_url
      image = Upload.get_from_url(object.image_url) rescue false
      return ListHelper.create_thumbnails(object.id, image, object.image_url)
    end

    def topic_post_actions
      return [] if !scope.current_user
      PostAction.where(post_id: topic_post_id, user_id: scope.current_user.id)
    end

    def topic_like_action
      topic_post_actions.select {|a| a.post_action_type_id == PostActionType.types[:like]}
    end

    def topic_post
      Post.find(topic_post_id)
    end

    def topic_post_bookmarked
      !!topic_post_actions.any?{|a| a.post_action_type_id == PostActionType.types[:bookmark]}
    end

    def topic_post_liked
      topic_like_action.any?
    end

    def topic_post_like_count
      topic_post.like_count
    end

    def include_topic_post_like_count?
      topic_post_like_count > 0
    end

    def topic_post_can_like
      post = topic_post
      return false if !scope.current_user || post.user_id == scope.current_user.id
      scope.post_can_act?(post, PostActionType.types[:like], taken_actions: topic_post_actions)
    end

    def topic_post_can_unlike
      return false if !scope.current_user
      action = topic_like_action[0]
      !!(action && (action.user_id == scope.current_user.id) && (action.created_at > SiteSetting.post_undo_action_window_mins.minutes.ago))
    end

  end

  TopicList.preloaded_custom_fields << "accepted_answer_post_id" if TopicList.respond_to? :preloaded_custom_fields
  TopicList.preloaded_custom_fields << "thumbnails" if TopicList.respond_to? :preloaded_custom_fields

  add_to_serializer(:basic_category, :list_excerpts) {object.custom_fields["list_excerpts"]}
  add_to_serializer(:basic_category, :list_thumbnails) {object.custom_fields["list_thumbnails"]}
  add_to_serializer(:basic_category, :list_actions) {object.custom_fields["list_actions"]}
  add_to_serializer(:basic_category, :list_category_badge_move) {object.custom_fields["list_category_badge_move"]}
end
