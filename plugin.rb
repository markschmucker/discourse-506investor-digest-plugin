# name: custom-digest
# about: Custom digest
# authors: Muhlis Budi Cahyono (muhlisbc@gmail.com) and Mark Schmucker
# version: 0.1.3
# url: https://github.com/markschmucker/discourse-506investor-digest-plugin
# enabled_site_setting: custom_digest_enabled

after_initialize {
  class ::Jobs::EnqueueDigestEmails
    def execute(args)
      return unless SiteSetting.custom_digest_enabled
      return if SiteSetting.disable_digest_emails? || SiteSetting.private_email?

      DistributedMutex.synchronize("custom_digest", validity: 180.minutes) {
        users = User.where(id: target_user_ids)
        return if users.blank?

        special_post = nil
        special_post_id = SiteSetting.custom_digest_special_post.to_i
        if special_post_id > 0
          special_post = Post.find_by(id: special_post_id)
        end
        
        favorite_posts = get_favorite_posts
        favorite_post_id = nil
        if favorite_posts.length > 0
          favorite_post_id = favorite_posts[0].id
        end
        
        users.each do |user|
          begin
            # Each user gets a fresh Excon connection. Sharing a single connection
            # across the batch caused 502s mid-loop once Cloudflare/Netlify's edge
            # closed the keep-alive — every subsequent user POSTed onto a degraded
            # socket and got rejected at the gateway.
            custom_digest = CustomDigest.new(user)

            if user.custom_fields['last_digest_special_post'].to_i != special_post_id
              custom_digest.special_post = special_post
            end

            if user.custom_fields['last_digest_favorite_post'].to_i != favorite_post_id
              custom_digest.favorite_posts = favorite_posts
            end

            custom_digest.deliver

            # Align to night in US. The second email will be a non-standard interval,
            # but will remain standard after that. 10:00 is 7:30 pm ASP.
            lda = Time.now
            if user.user_option.digest_after_minutes >= 1440
              lda = Time.new(lda.year, lda.month, lda.day, 10, 0, 0)
            end

            user.last_digest_at = lda
            user.save

            user.custom_fields['last_digest_special_post'] = special_post_id
            user.custom_fields['last_digest_favorite_post'] = favorite_post_id
            user.save_custom_fields
          rescue => e
            # Isolate per-user failures so one bad user doesn't abort the batch.
            # last_digest_at is left untouched, so the user is retried next run.
            Discourse.warn_exception(e, message: "custom-digest failed for #{user.username}")
          end

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
      user = User.find_by_username('DoNotChangeMyUsername')
      min_date = Time.now - (1 * 29 * 60 * 60)
      
      posts = Post
          .order("posts.like_count DESC")
          .for_mailing_list(user, min_date)
          .where('posts.post_type = ?', Post.types[:regular])
          .where('posts.deleted_at IS NULL AND posts.hidden = false AND posts.user_deleted = false')
          .where("posts.post_number > ?", 1)
          .where('posts.created_at < ?', (SiteSetting.editing_grace_period || 0).seconds.ago)
          .where("posts.like_count > ?", 5)
          .limit(5)
      
      posts
    end
    
  end

  class ::CustomDigest
    ENDPOINT = "https://506investorgroup.com"
    PATH     = "/.netlify/functions/digest-webhook"

    def self.create_connection
      Excon.new(ENDPOINT,
        headers: {
          "Content-Type"     => "application/json",
          "x-webhook-secret" => SiteSetting.custom_digest_webhook_secret,
        },
        expects: [200, 201])
    end

    attr_accessor :since, :special_post, :favorite_posts

    # Hard cap on how far back the digest looks, regardless of the user's
    # digest_after_minutes preference. Discourse added very long intervals
    # (3 months, 6 months) that this plugin can't sanely produce a single
    # email for — the activity query would pull most of the forum.
    MAX_WINDOW = 7.days

    def initialize(user, connection = nil)
      @user = user
      @connection = connection || CustomDigest.create_connection
      pref_since = Time.now - (@user.user_option.digest_after_minutes * 60)
      cap_since  = Time.now - MAX_WINDOW
      @since = [pref_since, cap_since].max
    end

    def deliver
      @connection.post(path: PATH, body: json)
    end

    def activity
      # 1) Find topic IDs the user is eligible to see with at least one post
      #    in the @since window. Do NOT use includes(:posts) here — that would
      #    preload every post of every topic (potentially thousands), which
      #    was the root of the per-user hang for users with wide windows.
      topic_ids = Topic
        .joins(:posts)
        .for_digest(@user, 100.years.ago)
        .where("posts.created_at > ?", @since)
        .distinct
        .pluck(:id)

      return [] if topic_ids.empty?

      # 2) Bulk-fetch only the posts within the window, with their authors
      #    and topics eager-loaded. One query, no N+1 in fmt_post.
      post_scope = Post
        .where(topic_id: topic_ids)
        .where("created_at > ?", @since)
      unless @user.staff?
        post_scope = post_scope.where("post_type <> ?", Post.types[:whisper])
      end
      recent_posts = post_scope.includes(:user, :topic).to_a
      posts_by_topic = recent_posts.group_by(&:topic_id)

      # 3) Build the per-topic structures from windowed posts only.
      Topic.where(id: posts_by_topic.keys).includes(:category, :tags).map do |t|
        posts = posts_by_topic[t.id] || []
        next if posts.empty?
        {
          topic_name: t.title,
          topic_url: t.url,
          topic_emblem_or_color: t.category.color,
          topic_categories: [t.category.parent_category&.name, t.category.name].compact,
          topic_tags: t.tags.map(&:name),
          slug: t.slug,
          posts: posts.map { |post| fmt_post(post) }
        }
      end.compact
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
      # Use the preloaded association when available (activity loop). Falls
      # back to a single lazy query for special_post / favorite_posts, which
      # are at most a handful.
      topic_title = post.topic.fancy_title
      {
        username: post.user.username,
        url: post.full_url,
        avatar: post.user.small_avatar_url,
        timestamp: post.created_at.iso8601,
        raw: post.raw,
        cooked: post.cooked,
        topic_title: topic_title
      }
    end
  end
}
