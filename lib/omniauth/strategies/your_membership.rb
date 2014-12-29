require 'omniauth-oauth2'
require 'builder'

module OmniAuth
  module Strategies
    class YourMembership < OmniAuth::Strategies::OAuth2

      option :client_options, {
        site: 'https://api.yourmembership.com',
        auth_token: '1683B512-5D53-42FF-BB7C-AE8EC6C155BA'
      }

      option :name, 'your_membership'

      uid { raw_member_info.xpath('//ID').children.text }

      info do
        {
          first_name: raw_member_info.xpath('//FirstName').children.text,
          last_name: raw_member_info.xpath('//LastName').children.text,
          email: raw_member_info.xpath('//EmailAddr').children.text,
          member_type: raw_member_info.xpath('//MemberTypeCode').children.text,
          is_active_member: is_active_member
        }
      end

      extra do
        { :raw_info => raw_info }
      end

      def creds
        self.access_token
      end

      def request_phase
        slug = session['omniauth.params']['origin'].gsub(/\//,"")

        session_id = create_session
        auth_url = create_token(session_id, callback_url, slug)
        redirect auth_url
      end

      def callback_phase
        if url_session_id

          self.access_token = {
            :token => url_session_id
          }

          self.env['omniauth.auth'] = auth_hash
          self.env['omniauth.origin'] = '/' + request.params['slug']
          call_app!
        else
          fail!(:invalid_credentials)
        end
      end

      def auth_hash
        hash = AuthHash.new(:provider => name, :uid => uid)
        hash.info = info
        hash.credentials = creds
        hash
      end

      def raw_member_info
        @raw_member_info ||= get_member_info
      end

      private

      def auth_token
        options.client_options.auth_token
      end

      def create_session
        response = Typhoeus.post(options.client_options.site, body: session_xml)

        if response.success?
          doc = Nokogiri::XML(response.body)
          doc.xpath('//SessionID').children.text
        else
          nil
        end
      end

      def create_token(session_id, callback, slug)
        response = Typhoeus.post(options.client_options.site, body: token_xml(session_id, callback, slug))

        if response.success?
          doc = Nokogiri::XML(response.body)
          doc.xpath('//GoToUrl').children.text
        else
          nil
        end
      end

      def get_member_info
        response = Typhoeus.post(options.client_options.site, body: member_xml)

        if response.success?
          doc = Nokogiri::XML(response.body)
        else
          nil
        end
      end

      def is_active_member
        raw_member_info.xpath('//MembershipExpiry').children.text.present? &&
          Date.parse(raw_member_info.xpath('//MembershipExpiry').children.text) >= Date.today
      end

      def member_xml
        xml_builder = ::Builder::XmlMarkup.new
        xml_builder.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
        xml_builder.YourMembership {
          xml_builder.Version '2.00'
          xml_builder.ApiKey '1683B512-5D53-42FF-BB7C-AE8EC6C155BA'
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
        callback_url = "#{callback}?slug=#{slug}&session_id=#{session_id}"

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

      def url_session_id
        request.params['session_id']
      end
    end
  end
end
