#! /usr/bin/env ruby
require 'spec_helper'

require 'puppet/ssl/certificate_revocation_list'

describe Puppet::SSL::CertificateRevocationList do
  before do
    ca = Puppet::SSL::CertificateAuthority.new
    ca.generate_ca_certificate
    @cert = ca.host.certificate.content
    @key = ca.host.key.content
    @class = Puppet::SSL::CertificateRevocationList
  end

  def expects_time_close_to_now(time)
    expect(time.to_i).to be_within(5*60).of(Time.now.to_i)
  end

  def expects_time_close_to_five_years(time)
    future = Time.now + Puppet::SSL::CertificateRevocationList::FIVE_YEARS
    expect(time.to_i).to be_within(5*60).of(future.to_i)
  end

  it "should only support the text format" do
    @class.supported_formats.should == [:s]
  end

  describe "when converting from a string" do
    it "should create a CRL instance with its name set to 'foo' and its content set to the extracted CRL" do
      crl = stub 'crl', :is_a? => true
      OpenSSL::X509::CRL.expects(:new).returns(crl)

      mycrl = stub 'sslcrl'
      mycrl.expects(:content=).with(crl)

      @class.expects(:new).with("foo").returns mycrl

      @class.from_s("my crl").should == mycrl
    end
  end

  describe "when an instance" do
    before do
      @class.any_instance.stubs(:read_or_generate)

      @crl = @class.new("whatever")
    end

    it "should always use 'crl' for its name" do
      @crl.name.should == "crl"
    end

    it "should have a content attribute" do
      @crl.should respond_to(:content)
    end
  end

  describe "when generating the crl" do
    before do
      @crl = @class.new("crl")
    end

    it "should set its issuer to the subject of the passed certificate" do
      @crl.generate(@cert, @key).issuer.should == @cert.subject
    end

    it "should set its version to 1" do
      @crl.generate(@cert, @key).version.should == 1
    end

    it "should create an instance of OpenSSL::X509::CRL" do
      @crl.generate(@cert, @key).should be_an_instance_of(OpenSSL::X509::CRL)
    end

    # taken from certificate_factory_spec.rb
    it "should add an extension for the CRL number" do
      @crl.generate(@cert, @key).extensions.map { |x| x.to_h }.find { |x| x["oid"] == "crlNumber" }.should ==
        { "oid"       => "crlNumber",
          "value"     => "0",
          "critical"  => false }
    end

    it "returns the last update time in UTC" do
      # http://tools.ietf.org/html/rfc5280#section-5.1.2.4
      thisUpdate = @crl.generate(@cert, @key).last_update
      thisUpdate.should be_utc
      expects_time_close_to_now(thisUpdate)
    end

    it "returns the next update time in UTC 5 years from now" do
      # http://tools.ietf.org/html/rfc5280#section-5.1.2.5
      nextUpdate = @crl.generate(@cert, @key).next_update
      nextUpdate.should be_utc
      expects_time_close_to_five_years(nextUpdate)
    end

    it "should verify using the CA public_key" do
      @crl.generate(@cert, @key).verify(@key.public_key).should be_true
    end

    it "should set the content to the generated crl" do
      # this test shouldn't be needed since we test the return of generate() which should be the content field
      @crl.generate(@cert, @key)
      @crl.content.should be_an_instance_of(OpenSSL::X509::CRL)
    end
  end

  # This test suite isn't exactly complete, because the
  # SSL stuff is very complicated.  It just hits the high points.
  describe "when revoking a certificate" do
    before do
      @crl = @class.new("crl")
      @crl.generate(@cert, @key)

      Puppet::SSL::CertificateRevocationList.indirection.stubs :save

    end

    it "should require a serial number and the CA's private key" do
      expect { @crl.revoke }.to raise_error(ArgumentError)
    end

    it "should default to OpenSSL::OCSP::REVOKED_STATUS_KEYCOMPROMISE as the revocation reason" do
      # This makes it a bit more of an integration test than we'd normally like, but that's life
      # with openssl.
      reason = OpenSSL::ASN1::Enumerated(OpenSSL::OCSP::REVOKED_STATUS_KEYCOMPROMISE)
      OpenSSL::ASN1.expects(:Enumerated).with(OpenSSL::OCSP::REVOKED_STATUS_KEYCOMPROMISE).returns reason

      @crl.revoke(1, @key)
    end

    it "should mark the CRL as updated at a time that makes it valid now" do
      @crl.revoke(1, @key)

      expects_time_close_to_now(@crl.content.last_update)
    end

    it "should mark the CRL valid for five years" do
      @crl.revoke(1, @key)

      expects_time_close_to_five_years(@crl.content.next_update)
    end

    it "should sign the CRL with the CA's private key and a digest instance" do
      @crl.content.expects(:sign).with { |key, digest| key == @key and digest.is_a?(OpenSSL::Digest::SHA1) }
      @crl.revoke(1, @key)
    end

    it "should save the CRL" do
      Puppet::SSL::CertificateRevocationList.indirection.expects(:save).with(@crl, nil)
      @crl.revoke(1, @key)
    end
  end
end
