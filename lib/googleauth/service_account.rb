# Copyright 2015, Google Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#     * Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following disclaimer
# in the documentation and/or other materials provided with the
# distribution.
#     * Neither the name of Google Inc. nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require "googleauth/signet"
require "googleauth/credentials_loader"
require "googleauth/json_key_reader"
require "jwt"
require "multi_json"
require "stringio"

module Google
  # Module Auth provides classes that provide Google-specific authorization
  # used to access Google APIs.
  module Auth
    # Authenticates requests using Google's Service Account credentials via an
    # OAuth access token.
    #
    # This class allows authorizing requests for service accounts directly
    # from credentials from a json key file downloaded from the developer
    # console (via 'Generate new Json Key').
    #
    # cf [Application Default Credentials](https://cloud.google.com/docs/authentication/production)
    class ServiceAccountCredentials < Signet::OAuth2::Client
      TOKEN_CRED_URI = "https://www.googleapis.com/oauth2/v4/token".freeze
      extend CredentialsLoader
      extend JsonKeyReader
      attr_reader :project_id
      attr_reader :quota_project_id

      def enable_self_signed_jwt?
        @enable_self_signed_jwt
      end

      # Creates a ServiceAccountCredentials.
      #
      # @param json_key_io [IO] an IO from which the JSON key can be read
      # @param scope [string|array|nil] the scope(s) to access
      def self.make_creds(options = {})
        json, json_key_io, scope = options.values_at(:json, :json_key_io, :scope)
        if json
          private_key = (json[:private_key] ? json[:private_key] : json["private_key"])
          client_email = (json[:client_email] ? json[:client_email] : json["client_email"])
        elsif json_key_io
          private_key, client_email = read_json_key(json_key_io)
    # LJC: from July 31, 2021 update
    #   json_key_io, scope, enable_self_signed_jwt, target_audience, audience, token_credential_uri =
    #     options.values_at :json_key_io, :scope, :enable_self_signed_jwt, :target_audience,
    #                       :audience, :token_credential_uri
    #   raise ArgumentError, "Cannot specify both scope and target_audience" if scope && target_audience
    #
    #   if json_key_io
    #     private_key, client_email, project_id, quota_project_id = read_json_key json_key_io
        else
          private_key = unescape ENV[CredentialsLoader::PRIVATE_KEY_VAR]
          client_email = ENV[CredentialsLoader::CLIENT_EMAIL_VAR]
          project_id = ENV[CredentialsLoader::PROJECT_ID_VAR]
          quota_project_id = nil
        end
        new(token_credential_uri: TOKEN_CRED_URI,
            audience: TOKEN_CRED_URI,
            scope: scope,
            issuer: client_email,
            signing_key: OpenSSL::PKey::RSA.new(private_key))
        # LJC: from July 31, 2021 update
        # project_id ||= CredentialsLoader.load_gcloud_project_id
        #
        # new(token_credential_uri:   token_credential_uri || TOKEN_CRED_URI,
        #     audience:               audience || TOKEN_CRED_URI,
        #     scope:                  scope,
        #     enable_self_signed_jwt: enable_self_signed_jwt,
        #     target_audience:        target_audience,
        #     issuer:                 client_email,
        #     signing_key:            OpenSSL::PKey::RSA.new(private_key),
        #     project_id:             project_id,
        #     quota_project_id:       quota_project_id)
        #   .configure_connection(options)
      end

      # Handles certain escape sequences that sometimes appear in input.
      # Specifically, interprets the "\n" sequence for newline, and removes
      # enclosing quotes.
      def self.unescape str
        str = str.gsub '\n', "\n"
        str = str[1..-2] if str.start_with?('"') && str.end_with?('"')
        str
      end

      def initialize options = {}
        @project_id = options[:project_id]
        @quota_project_id = options[:quota_project_id]
        @enable_self_signed_jwt = options[:enable_self_signed_jwt] ? true : false
        super options
      end

      # Extends the base class to use a transient
      # ServiceAccountJwtHeaderCredentials for certain cases.
      def apply! a_hash, opts = {}
        # Use a self-singed JWT if there's no information that can be used to
        # obtain an OAuth token, OR if there are scopes but also an assertion
        # that they are default scopes that shouldn't be used to fetch a token.
        if target_audience.nil? && (scope.nil? || enable_self_signed_jwt?)
          apply_self_signed_jwt! a_hash
        else
          super
        end
      end

      private

      def apply_self_signed_jwt! a_hash
        # Use the ServiceAccountJwtHeaderCredentials using the same cred values
        cred_json = {
          private_key: @signing_key.to_s,
          client_email: @issuer,
          project_id: @project_id,
          quota_project_id: @quota_project_id
        }
        key_io = StringIO.new MultiJson.dump(cred_json)
        alt = ServiceAccountJwtHeaderCredentials.make_creds json_key_io: key_io, scope: scope
        alt.apply! a_hash
      end
    end

    # Authenticates requests using Google's Service Account credentials via
    # JWT Header.
    #
    # This class allows authorizing requests for service accounts directly
    # from credentials from a json key file downloaded from the developer
    # console (via 'Generate new Json Key').  It is not part of any OAuth2
    # flow, rather it creates a JWT and sends that as a credential.
    #
    # cf [Application Default Credentials](https://cloud.google.com/docs/authentication/production)
    class ServiceAccountJwtHeaderCredentials
      JWT_AUD_URI_KEY = :jwt_aud_uri
      AUTH_METADATA_KEY = Signet::OAuth2::AUTH_METADATA_KEY
      TOKEN_CRED_URI = "https://www.googleapis.com/oauth2/v4/token".freeze
      SIGNING_ALGORITHM = "RS256".freeze
      EXPIRY = 60
      extend CredentialsLoader
      extend JsonKeyReader
      attr_reader :project_id
      attr_reader :quota_project_id

      # Create a ServiceAccountJwtHeaderCredentials.
      #
      # @param json_key_io [IO] an IO from which the JSON key can be read
      # @param scope [string|array|nil] the scope(s) to access
      def self.make_creds options = {}
        json_key_io, scope = options.values_at :json_key_io, :scope
        new json_key_io: json_key_io, scope: scope
      end

      # Initializes a ServiceAccountJwtHeaderCredentials.
      #
      # @param json_key_io [IO] an IO from which the JSON key can be read
      def initialize options = {}
        json_key_io = options[:json_key_io]
        if json_key_io
          @private_key, @issuer, @project_id, @quota_project_id =
            self.class.read_json_key json_key_io
        else
          @private_key = ENV[CredentialsLoader::PRIVATE_KEY_VAR]
          @issuer = ENV[CredentialsLoader::CLIENT_EMAIL_VAR]
          @project_id = ENV[CredentialsLoader::PROJECT_ID_VAR]
          @quota_project_id = nil
        end
        @project_id ||= CredentialsLoader.load_gcloud_project_id
        @signing_key = OpenSSL::PKey::RSA.new @private_key
        @scope = options[:scope]
      end

      # Construct a jwt token if the JWT_AUD_URI key is present in the input
      # hash.
      #
      # The jwt token is used as the value of a 'Bearer '.
      def apply! a_hash, opts = {}
        jwt_aud_uri = a_hash.delete JWT_AUD_URI_KEY
        return a_hash if jwt_aud_uri.nil? && @scope.nil?
        jwt_token = new_jwt_token jwt_aud_uri, opts
        a_hash[AUTH_METADATA_KEY] = "Bearer #{jwt_token}"
        a_hash
      end

      # Returns a clone of a_hash updated with the authoriation header
      def apply a_hash, opts = {}
        a_copy = a_hash.clone
        apply! a_copy, opts
        a_copy
      end

      # Returns a reference to the #apply method, suitable for passing as
      # a closure
      def updater_proc
        proc { |a_hash, opts = {}| apply a_hash, opts }
      end

      protected

      # Creates a jwt uri token.
      def new_jwt_token jwt_aud_uri = nil, options = {}
        now = Time.new
        skew = options[:skew] || 60
        assertion = {
          "iss" => @issuer,
          "sub" => @issuer,
          "exp" => (now + EXPIRY).to_i,
          "iat" => (now - skew).to_i
        }

        jwt_aud_uri = nil if @scope

        assertion["scope"] = Array(@scope).join " " if @scope
        assertion["aud"] = jwt_aud_uri if jwt_aud_uri

        JWT.encode assertion, @signing_key, SIGNING_ALGORITHM
      end
    end
  end
end
