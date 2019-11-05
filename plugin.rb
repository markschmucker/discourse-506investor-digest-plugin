# name: custom-digest
# about: Custom digest
# authors: Muhlis Budi Cahyono (muhlisbc@gmail.com) and Mark Schmucker
# version: 0.1.2
# url: https://github.com/markschmucker/discourse-506investor-digest-plugin

after_initialize {
  class ::Jobs::EnqueueDigestEmails
    def execute(args)
      return if SiteSetting.disable_digest_emails? || SiteSetting.private_email?

      DistributedMutex.synchronize("custom_digest", validity: 180.minutes) {
        users = User.where(id: target_user_ids)
        return if users.blank?
        
        connection = CustomDigest.create_connection
        
        special_post = nil
        special_post_id = SiteSetting.custom_digest_special_post.to_i
        if special_post_id > 0
          special_post = Post.find_by(id: special_post_id)
        end
        
        favorite_posts = get_favorite_posts
        favorite_post_id = nil
        if favorite_posts
          favorite_post_id = favorite_posts[0].id
        end
        
        # for testing
        #users = users.select { |u| u.username == "admin" }

        users.each do |user|
          custom_digest = CustomDigest.new(user, connection)
          
          
          if user.custom_fields['last_digest_special_post'].to_i != special_post_id
            custom_digest.special_post = special_post
          end
          
          if user.custom_fields['last_digest_favorite_post'].to_i != favorite_post_id
            custom_digest.favorite_posts = favorite_posts
          end
          
          custom_digest.deliver

          # Align to night in US. The second email will be a non-standard interval,
          # but will remain standard after that.
          lda = Time.now
          if user.user_option.digest_after_minutes >= 1440
            lda = Time.new(lda.year, lda.month, lda.day, 8, 0, 0)
          end
          
          user.last_digest_at = lda
          user.save
          
          user.custom_fields['last_digest_special_post'] = special_post_id
          user.custom_fields['last_digest_favorite_post'] = favorite_post_id
          user.save_custom_fields

          sleep 2
        end
      }
    end

    def target_user_ids
      # Users who want to receive digest email within their chosen digest email frequency
      query = User.real
        .not_suspended
        .activated
        .where(staged: false)
        .joins(:user_option, :user_stat)
        .where("user_options.email_digests")
        .where("user_stats.bounce_score < #{SiteSetting.bounce_score_threshold}")
        .where("COALESCE(last_digest_at, '2010-01-01') <= CURRENT_TIMESTAMP - ('1 MINUTE'::INTERVAL * user_options.digest_after_minutes)")

      # If the site requires approval, make sure the user is approved
      query = query.where("approved OR moderator OR admin") if SiteSetting.must_approve_users?

      query.pluck(:id)
    end
    
    def get_favorite_posts
      user = User.find_by_username('JohnDoe')
      min_date = Time.now - (1 * 29 * 60 * 60)
      
      posts = Post
          .order("posts.like_count DESC")
          .for_mailing_list(user, min_date)
          .where('posts.post_type = ?', Post.types[:regular])
          .where('posts.deleted_at IS NULL AND posts.hidden = false AND posts.user_deleted = false')
          .where("posts.post_number > ?", 1)
          .where('posts.created_at < ?', (SiteSetting.editing_grace_period || 0).seconds.ago)
          .limit(10)
      
      max_like_count = posts.map { |post| post.like_count }.max
      
      favorite_posts = nil
      if max_like_count >= 4
        favorite_posts = posts.select { |p| p.like_count == max_like_count }
      end
      
      favorite_posts
    end
    
  end

  class ::CustomDigest
    def self.create_connection
      headers = {
        "Content-Type" => "application/json"
      }

      Excon.new("http://digests.506investorgroup.com:8081", headers: headers, expects: [200, 201])
    end

    attr_accessor :since, :special_post, :favorite_posts

    def initialize(user, connection = nil)
      @user = user
      @connection = connection || CustomDigest.create_connection
      @since = Time.now - (@user.user_option.digest_after_minutes * 60)
    end

    def deliver
      @connection.post(path: "/", body: json)
    end

    def activity
      #@since ||= (@user.last_emailed_at || 1.month.ago)

      topics = Topic
        .joins(:posts)
        .includes(:posts)
        .for_digest(@user, 100.years.ago)
        .where("posts.created_at > ?", @since)

      unless @user.staff?
        topics = topics.where("posts.post_type <> ?", Post.types[:whisper])
      end

      topics.uniq.map do |t|
        {
          topic_name: t.title,
          topic_url: t.url,
          topic_emblem_or_color: t.category.color,
          topic_categories: [t.category.parent_category&.name, t.category.name].compact,
          topic_tags: t.tags.pluck(:name),
          slug: t.slug,
          posts: t.posts.map { | post| fmt_post(post) }
        }
      end
    end

    def json
      result = {
        username: @user.username,
        email: @user.email,
        frequency: @user.user_option.digest_after_minutes,
        since: @since.iso8601,
        base_url: Discourse.base_url,
        activity: activity
      }

      if @special_post
        result[:special_post] = fmt_post(@special_post)
      end

      if @favorite_posts
        result[:favorite_posts] = @favorite_posts.map { |post| fmt_post(post) }
      end

      result.to_json
    end

    def fmt_post(post)
      {
        username: post.user.username,
        url: post.full_url,
        avatar: post.user.small_avatar_url,
        timestamp: post.created_at.iso8601,
        raw: post.raw,
        cooked: post.cooked
      }
    end
  end
}
