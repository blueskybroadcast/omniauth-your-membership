require 'omniauth-oauth2'
require 'builder'
require 'active_support'
require 'active_support/core_ext/object/blank'

module OmniAuth
  module Strategies
    class YourMembership < OmniAuth::Strategies::OAuth2
      LIMIT_EXCEEDED_ERR_CODE = '903'.freeze

      option :client_options, {
        site: 'https://api.yourmembership.com',
        auth_token: '1683B512-5D53-42FF-BB7C-AE8EC6C155BA',
        private_key: 'MUST_BE_SET',
        sync_standard_groups: false,
        sync_custom_field_groups: false,
        sa_passcode: 'MUST_BE_SET',
        custom_fields_sync: false,
        custom_field_keys: []
      }

      option :name, 'your_membership'

      uid { raw_member_info.xpath('//ID').children.text }

      info do
        data = {
          first_name: raw_member_info.xpath('//FirstName').children.text,
          last_name: raw_member_info.xpath('//LastName').children.text,
          email: raw_member_info.xpath('//EmailAddr').children.text,
          member_type: raw_member_info.xpath('//MemberTypeCode').children.text,
          username: raw_member_info.xpath('//Username').children.text,
          is_active_member: active_member?
        }
        data[:custom_fields_data] = custom_fields_data if sync_custom_fields?

        if add_groups_data?
          group_codes = []
          group_codes += standard_groups if sync_standard_groups?
          group_codes += custom_field_groups if sync_custom_field_groups?
          data[:groups] = group_codes
        end

        data
      end

      extra do
        { raw_info: raw_info }
      end

      def creds
        self.access_token
      end

      def request_phase
        account = Account.find_by(slug: account_slug)
        @app_event = account.app_events.create(activity_type: 'sso')

        session_id = create_session
        auth_url = create_token(session_id, callback_url, account_slug)
        if session_id.blank? || auth_url.blank?
          @app_event.logs.create(level: 'error', text: 'Session ID or Auth URL is absent')
          @app_event.fail!
          return fail!(:invalid_credentials)
        end
        redirect auth_url
      rescue QuotaExceededError => _e
        redirect "#{callback_url}?slug=#{account_slug}&event_id=#{@app_event.id}&quota_exceeded=true"
      end

      def callback_phase
        account = Account.find_by(slug: account_slug)
        @app_event = account.app_events.where(id: request.params['event_id']).first_or_create(activity_type: 'sso')
        self.env['omniauth.origin'] = '/' + account_slug
        self.env['omniauth.app_event_id'] = @app_event.id

        if url_session_id
          self.access_token = { token: url_session_id }
          self.env['omniauth.auth'] = auth_hash
          self.env['omniauth.redirect_url'] = request.params['redirect_url'].presence
          finalize_app_event
          call_app!
        else
          if request.params['quota_exceeded'].to_b
            call_app_with_quota_exceeded_error
          else
            @app_event.logs.create(level: 'error', text: 'Session ID is absent')
            @app_event.fail!
            fail!(:invalid_credentials)
          end
        end
      rescue QuotaExceededError => _e
        call_app_with_quota_exceeded_error
      end

      def auth_hash
        hash = AuthHash.new(provider: name, uid: uid)
        hash.info = info
        hash.credentials = creds
        hash
      end

      def raw_member_info
        @raw_member_info ||= get_member_info
      end

      def raw_group_member_info
        @group_member_info ||= get_group_member_codes
      end

      private

      def account_slug
        session['omniauth.params']&.[]('origin')&.gsub(/\//, '') || request.params['slug'].presence || request.params['origin']&.tr('/', '')
      end

      def call_app_with_quota_exceeded_error
        Rails.logger.error "=============!!! YourMembership Requests limit exceeded during SSO !!!============="
        @app_event.logs.create(level: 'error', text: 'Requests limit exceeded')
        @app_event.fail!
        self.env['omniauth.auth'] = true
        self.env['omniauth.error'] = 'custom_error'
        self.env['omniauth.error.type'] = 'quota_exceeded'
        call_app!
      end

      def custom_field_keys
        options.client_options.custom_field_keys
      end

      def add_groups_data?
        sync_standard_groups? || sync_custom_field_groups?
      end

      def sync_standard_groups?
        options.client_options.sync_standard_groups
      end

      def sync_custom_field_groups?
        options.client_options.sync_custom_field_groups
      end

      def sync_custom_fields?
        options.client_options.custom_fields_sync
      end

      def standard_groups
        raw_group_member_info.xpath('//Group').map { |node| node.attributes['Code'].value }.uniq
      end

      def custom_field_groups
        custom_fields_data.map do |k, v|
          values = v.split(';')
          values.map { |val| "#{k.downcase}@#{val.downcase}" }
        end.compact.uniq.flatten
      end

      def custom_fields_data
        @custom_fields_data ||=
          custom_field_keys.to_a.each_with_object({}) do |key, hash|
            custom_field_response = raw_member_info.xpath("//CustomFieldResponse[@FieldCode='#{key}']//Value")
            hash[key.downcase] = parse_custom_field_values(custom_field_response).compact.join(';')
          end
      end

      def parse_custom_field_values(custom_field_response)
        custom_field_response.map do |custom_field_value|
          custom_field_value.children.text.presence
        end
      end

      def app_event_log(callee, response = nil)
        if response
          response_log = "YourMembership Authentication Response (#{callee.to_s.humanize}) (code: #{response&.code}):\n#{response.body}"
          log_level = response.success? ? 'info' : 'error'
          @app_event.logs.create(level: log_level, text: response_log)
        else
          request_log = "YourMembership Authentication Request (#{callee.to_s.humanize}):\nPOST #{options.client_options.site}"
          @app_event.logs.create(level: 'info', text: request_log)
        end
      end

      def auth_token
        options.client_options.auth_token
      end

      def private_api_key
        options.client_options.private_key
      end

      def sa_passcode
        options.client_options.sa_passcode
      end

      def create_session
        app_event_log(__callee__)
        response = Typhoeus.post(options.client_options.site, body: session_xml)
        app_event_log(__callee__, response)

        if response.success?
          doc = Nokogiri::XML(response.body)
          check_if_requests_limit_reached(doc)
          doc.xpath('//SessionID').children.text
        else
          nil
        end
      end

      def create_token(session_id, callback, slug)
        app_event_log(__callee__)
        response = Typhoeus.post(options.client_options.site, body: token_xml(session_id, callback, slug))
        app_event_log(__callee__, response)

        if response.success?
          doc = Nokogiri::XML(response.body)
          check_if_requests_limit_reached(doc)
          doc.xpath('//GoToUrl').children.text
        else
          nil
        end
      end

      def check_if_requests_limit_reached(parsed_response)
        raise QuotaExceededError if parsed_response.xpath('//ErrCode')&.text == LIMIT_EXCEEDED_ERR_CODE
      end

      def finalize_app_event
        app_event_data = {
          user_info: {
            uid: uid,
            first_name: info[:first_name],
            last_name: info[:last_name],
            email: info[:email]
          }
        }

        @app_event.update(raw_data: app_event_data)
      end

      def get_member_info
        app_event_log(__callee__)
        response = Typhoeus.post(options.client_options.site, body: member_xml)
        app_event_log(__callee__, response)

        if response.success?
          doc = Nokogiri::XML(response.body)
          check_if_requests_limit_reached(doc)
          doc
        else
          nil
        end
      end

      def get_group_member_codes
        app_event_log(__callee__)
        response = Typhoeus.post(options.client_options.site, body: groups_xml)
        app_event_log(__callee__, response)

        if response.success?
          doc = Nokogiri::XML(response.body)
          check_if_requests_limit_reached(doc)
          doc
        else
          nil
        end
      end

      def active_member?
        raw_member_info.xpath('//MembershipExpiry').children.text.present? &&
          Date.parse(raw_member_info.xpath('//MembershipExpiry').children.text) >= Date.today
      end

      def member_xml
        xml_builder = ::Builder::XmlMarkup.new
        xml_builder.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
        xml_builder.YourMembership {
          xml_builder.Version '2.00'
          xml_builder.ApiKey auth_token
          xml_builder.CallID '003'
          xml_builder.SessionID url_session_id
          xml_builder.Call(Method: "Member.Profile.Get")
        }
        xml_builder.target!
      end

      def session_xml
        xml_builder = ::Builder::XmlMarkup.new
        xml_builder.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
        xml_builder.YourMembership {
          xml_builder.Version '2.00'
          xml_builder.ApiKey auth_token
          xml_builder.CallID '001'
          xml_builder.Call(Method: "Session.Create")
        }
        xml_builder.target!
      end

      def token_xml(session_id, callback, slug)
        callback_url = "#{callback}?slug=#{slug}&session_id=#{session_id}&event_id=#{@app_event.id}&redirect_url=#{request.params['redirect_url']}"

        xml_builder = ::Builder::XmlMarkup.new
        xml_builder.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
        xml_builder.YourMembership {
          xml_builder.Version '2.00'
          xml_builder.ApiKey auth_token
          xml_builder.CallID '002'
          xml_builder.SessionID session_id
          xml_builder.Call(Method: "Auth.CreateToken") {
            xml_builder.RetUrl callback_url
          }
        }
      end

      def groups_xml
        xml_builder = ::Builder::XmlMarkup.new
        xml_builder.instruct! :xml, version: '1.0', encoding: 'UTF-8'
        xml_builder.YourMembership {
          xml_builder.Version '2.03'
          xml_builder.ApiKey private_api_key
          xml_builder.CallID '004'
          xml_builder.SaPasscode sa_passcode
          xml_builder.Call(Method: 'Sa.People.Profile.Groups.Get') {
            xml_builder.ID person_id
          }
        }
        xml_builder.target!
      end

      def person_id
        @person_id ||= raw_member_info.xpath('//ID').children.text
      end

      def url_session_id
        request.params['session_id']
      end
    end
  end
end
