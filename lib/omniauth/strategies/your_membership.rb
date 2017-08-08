require 'omniauth-oauth2'
require 'builder'
require 'active_support'
require 'active_support/core_ext/object/blank'

module OmniAuth
  module Strategies
    class YourMembership < OmniAuth::Strategies::OAuth2

      option :client_options, {
        site: 'https://api.yourmembership.com',
        auth_token: '1683B512-5D53-42FF-BB7C-AE8EC6C155BA',
        private_key: 'MUST_BE_SET',
        add_groups_data: false,
        sa_passcode: 'MUST_BE_SET'
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
        if add_groups_data?
          group_codes = raw_group_member_info.xpath('//Group').map { |node| node.attributes['Code'].value }
          group_codes.uniq!
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
        slug = session['omniauth.params']['origin'].gsub(/\//,"")
        account = Account.find_by(slug: slug)
        @app_event = account.app_events.create(activity_type: 'sso')

        session_id = create_session
        auth_url = create_token(session_id, callback_url, slug)
        unless session_id && auth_url
          @app_event.logs.create(level: 'error', text: 'Invalid credentials')
          @app_event.fail!
          return fail!(:invalid_credentials)
        end
        redirect auth_url
      end

      def callback_phase
        slug = request.params['slug']
        @app_event = account.app_events.where(id: request.params['event_id']).first_or_create(activity_type: 'sso')

        if url_session_id
          self.access_token = {
            token: url_session_id
          }

          self.env['omniauth.auth'] = auth_hash
          self.env['omniauth.origin'] = '/' + slug
          self.env['omniauth.app_event_id'] = @app_event.id
          finalize_app_event
          call_app!
        else
          @app_event.logs.create(level: 'error', text: 'Invalid credentials')
          @app_event.fail!
          fail!(:invalid_credentials)
        end
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

      def add_groups_data?
        options.client_options.add_groups_data
      end

      def app_event_log(callee, response = nil)
        if response
          response_log = "YourMembership Authentication Response (#{callee.to_s.humanize}) (code: #{response&.code}):\n#{response.inspect}"
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
          doc.xpath('//GoToUrl').children.text
        else
          nil
        end
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
          Nokogiri::XML(response.body)
        else
          nil
        end
      end

      def get_group_member_codes
        app_event_log(__callee__)
        response = Typhoeus.post(options.client_options.site, body: groups_xml)
        app_event_log(__callee__, response)

        if response.success?
          Nokogiri::XML(response.body)
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
        callback_url = "#{callback}?slug=#{slug}&session_id=#{session_id}&event_id=#{@app_event.id}"

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
