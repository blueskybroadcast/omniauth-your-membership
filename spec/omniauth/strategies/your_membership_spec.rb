require 'spec_helper'
require 'nokogiri'

describe OmniAuth::Strategies::YourMembership do
  subject { described_class.new('app_id', 'secret') }
  let(:app_event) { double('AppEvent', id: 1) }

  describe '#options' do
    describe '#name' do
      it { expect(subject.options.name).to be_eql('your_membership') }
    end

    describe '#client_options' do
      describe '#site' do
        it { expect(subject.options.client_options.site).to be_eql('https://api.yourmembership.com') }
      end

      describe '#auth_token' do
        it { expect(subject.options.client_options.auth_token).to be_eql('1683B512-5D53-42FF-BB7C-AE8EC6C155BA') }
      end

      describe '#sync_standard_groups' do
        it { expect(subject.options.client_options.sync_standard_groups).to be_eql(false) }
      end

      describe '#sync_custom_field_groups' do
        it { expect(subject.options.client_options.sync_custom_field_groups).to be_eql(false) }
      end

      describe '#sa_passcode' do
        it { expect(subject.options.client_options.sa_passcode).to be_eql('MUST_BE_SET') }
      end

      describe '#private_key' do
        it { expect(subject.options.client_options.private_key).to be_eql('MUST_BE_SET') }
      end

      describe '#custom_fields_sync' do
        it { expect(subject.options.client_options.custom_fields_sync).to be_eql(false) }
      end

      describe '#custom_field_keys' do
        it { expect(subject.options.client_options.custom_field_keys).to be_eql([]) }
      end
    end
  end

  describe '#info' do
    before do
      allow(subject).to receive(:raw_member_info).and_return(Nokogiri::XML(get_response_fixture('member')))
    end

    context 'first_name' do
      it 'returns correct first_name' do
        expect(subject.info[:first_name]).to be_eql('Elizabeth')
      end
    end

    context 'last_name' do
      it 'returns correct last_name' do
        expect(subject.info[:last_name]).to be_eql('Allen')
      end
    end

    context 'email' do
      it 'returns correct email' do
        expect(subject.info[:email]).to be_eql('demo@yourmembership.com')
      end
    end

    context 'member_type' do
      it 'returns correct member_type' do
        expect(subject.info[:member_type]).to be_eql('Alum')
      end
    end

    context 'username' do
      it 'returns correct username' do
        expect(subject.info[:username]).to be_eql('lizzy123')
      end
    end

    context 'is_active_member' do
      context 'when #active_member? returns true' do
        before { allow(subject).to receive(:active_member?).and_return(true) }

        it 'returns true' do
          expect(subject.info[:is_active_member]).to be_eql(true)
        end
      end

      context 'when #active_member? returns false' do
        before { allow(subject).to receive(:active_member?).and_return(false) }
      end

      it 'returns false' do
        expect(subject.info[:is_active_member]).to be_eql(false)
      end
    end

    context 'groups' do
      context 'when #sync_standard_groups? returns true' do
        before do
          allow(subject).to receive(:sync_standard_groups?).and_return(true)
          allow(subject).to receive(:raw_group_member_info).and_return(Nokogiri::XML(get_response_fixture('groups')))
        end

        it 'exists in info hash and has correct value' do
          info = subject.info

          expect(info).to have_key(:groups)
          expect(info[:groups]).to be_eql %w(2008 Tampa CONHS COSG ATBB)
        end
      end

      context 'when #sync_standard_groups? returns false' do
        before { allow(subject).to receive(:sync_standard_groups?).and_return(false) }

        it 'does not exists in info hash' do
          expect(subject.info).not_to have_key(:groups)
        end
      end

      context 'when #sync_custom_field_groups? returns true' do
        before do
          allow(subject).to receive(:sync_custom_field_groups?).and_return(true)
          allow(subject).to receive(:custom_field_keys).and_return(['CustomField1'])
          allow(subject).to receive(:raw_member_info).and_return(Nokogiri::XML(get_response_fixture('member')))
        end

        it 'exists in info hash and has correct value' do
          info = subject.info

          expect(info).to have_key(:groups)
          expect(info[:groups]).to be_eql ['customfield1@custom value 1', 'customfield1@custom value 2']
        end
      end

      context 'when #sync_custom_field_groups? returns false' do
        before { allow(subject).to receive(:sync_custom_field_groups?).and_return(false) }

        it 'does not exist in info hash' do
          expect(subject.info).not_to have_key(:groups)
        end
      end
    end
  end

  context 'custom_fields_data' do
    context 'if sync_custom_fields? is true' do
      before do
        allow(subject).to receive(:sync_custom_fields?).and_return(true)
        allow(subject).to receive(:custom_field_keys).and_return(['CustomField2'])
        allow(subject).to receive(:raw_member_info).and_return(Nokogiri::XML(get_response_fixture('member')))
      end

      it 'exists in info hash and has correct value' do
        info = subject.info

        expect(info).to have_key(:custom_fields_data)
        expect(info[:custom_fields_data]).to be_eql({ 'customfield2' => 'Custom value 1;Custom value 2' })
      end
    end

    context 'if sync_custom_fields? is true but custom_field_keys is empty' do
      before do
        allow(subject).to receive(:sync_custom_fields?).and_return(true)
        allow(subject).to receive(:custom_field_keys).and_return([])
        allow(subject).to receive(:raw_member_info).and_return(Nokogiri::XML(get_response_fixture('member')))
      end

      it 'exists in info hash and empty' do
        info = subject.info

        expect(info).to have_key(:custom_fields_data)
        expect(info[:custom_fields_data]).to be_eql({})
      end
    end

    context 'if sync_custom_fields? is false' do
      before do
        allow(subject).to receive(:sync_custom_fields?).and_return(false)
        allow(subject).to receive(:raw_member_info).and_return(Nokogiri::XML(get_response_fixture('member')))
      end

      it 'does not exist in info hash' do
        info = subject.info

        expect(info).not_to have_key(:custom_fields_data)
      end
    end
  end

  describe '#get_group_member_codes' do
    before do
      subject.instance_variable_set(:@app_event, app_event)
      allow(subject).to receive(:groups_xml).and_return('groups_xml')
      allow(subject).to receive(:person_id).and_return('person_id')
      allow(app_event).to receive_message_chain(:logs, :create).and_return(true)
    end

    context 'when response is success' do
      let(:expected) { get_response_fixture('groups') }

      before do
        stub_request(:post, 'https://api.yourmembership.com').
          with(body: 'groups_xml').
          to_return(status: 200, body: get_response_fixture('groups'))
      end

      it 'returns Nokogiri XML object with response body' do
        result = subject.send(:get_group_member_codes)

        expect(result).to be_kind_of(Nokogiri::XML::Document)
        expect(result.to_xml).to be_eql(expected)
      end
    end

    context 'when response is not success' do
      before do
        stub_request(:post, 'https://api.yourmembership.com').
          with(body: 'groups_xml').
          to_return(status: 422, body: '')
      end

      it 'returns nil' do
        expect(subject.send(:get_group_member_codes)).to be_nil
      end
    end
  end

  context 'xml builds' do
    before do
      allow(subject).to receive(:auth_token).and_return('auth_token')
      allow(subject).to receive(:person_id).and_return('person_id')
    end

    describe '#member_xml' do
      before { allow(subject).to receive(:url_session_id).and_return('url_session_id') }

      let(:expected) { get_request_fixture('member') }

      it 'builds correct xml' do
        result = to_xml(subject.send(:member_xml))

        expect(result).to be_eql expected
      end
    end

    describe '#session_xml' do
      let(:expected) { get_request_fixture('session') }

      it 'builds correct xml' do
        result = to_xml(subject.send(:session_xml))

        expect(result).to be_eql expected
      end
    end

    describe '#token_xml' do
      let(:session_id) { 'session_id' }
      let(:callback) { 'http://example.com/callback' }
      let(:slug) { 'slug' }
      let(:expected) { get_request_fixture('token') }

      before do
        subject.instance_variable_set(:@app_event, double('AppEvent', id: 1))
      end

      it 'builds correct xml' do
        result = to_xml(subject.send(:token_xml, session_id, callback, slug))

        expect(result).to be_eql expected
      end
    end

    describe '#groups_xml' do
      before { allow(subject).to receive(:sa_passcode).and_return('sa_passcode') }
      before { allow(subject).to receive(:private_api_key).and_return('private_api_key') }

      let(:expected) { get_request_fixture('groups') }

      it 'builds correct xml' do
        result = to_xml(subject.send(:groups_xml))

        expect(result).to be_eql expected
      end
    end
  end

  def to_xml(string)
    Nokogiri::XML(string).to_xml
  end

  def get_response_fixture(file_name)
    get_fixture("response/#{file_name}")
  end

  def get_request_fixture(file_name)
    get_fixture("request/#{file_name}")
  end

  def get_fixture(file_name)
    to_xml(IO.read("spec/fixtures/#{file_name}.xml"))
  end
end
