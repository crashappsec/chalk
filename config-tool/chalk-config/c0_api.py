import os
import jwt
import json
import requests

from auth0.authentication.token_verifier import TokenVerifier, AsymmetricSignatureVerifier
from auth0.authentication import Users

##Will eventually grab from appropriate secret store
AUTH0_DOMAIN = "testing-5o7i-a17.us.auth0.com"
AUTH0_CLIENT_ID = "XLBRu3kpIpJ7ry7AWX6823KworrfO3KE"
AUTH0_SECRET = "989izU7uv0BK6AMDHgjg1RTgtX-oJObtAeHRtE8PNsJXRM9tvstTzWGzwPnOMZ5B"

MODULE_LOCATION = os.path.abspath(os.path.dirname(__file__))

##ToDo - implement refresh logic for when refresh needs to be called (check HTTP error codes on access token usage)
##ToDo - add expiration timestamp rather than expires in 86400 (24 hours)

class CLIAuth(object):
    """
    Example class to perform OAuth2.0 Device Authorization Flow
    """
    def __init__(self, auth0_domain, auth0_client_id, auth0_secret):
        """
        """
        self.auth0_domain    = auth0_domain
        self.auth0_client_id = auth0_client_id
        self.auth0_secret    = auth0_secret
        self.auth0_algorithm = ["RS256"]
        self.auth0_scope     = "openid profile email offline_access"

        self.device_code_data = {'client_id': self.auth0_client_id,
                                 'scope'    : self.auth0_scope}
        
        self.tokens_path       = ".chalk_tokens.json"
        self.token_file_obj    = None
        self.token_json        = {}
        self.id_token_json     = {}
        self.device_code_json  = {}
        self.current_user_name = ""
        self.authenticated     = False

        self.jwks_url = "https://%s/.well-known/jwks.json"%(self.auth0_domain)
        self.issuer   = "https://%s/"%(self.auth0_domain)

    def oidc_token_validate(self, token):
        """
        """
        sv = AsymmetricSignatureVerifier(self.jwks_url)
        tv = TokenVerifier(signature_verifier=sv, issuer=self.issuer, audience=self.auth0_client_id)
        tv.verify(token)

    def decode_id_token(self, token):
        """
        """
        try:
            #ToDo FIXME verifications
            dec_token = jwt.decode(self.token_json["id_token"], algorithm=["RS256"], options={"verify_signature": False})
            self.id_token_json = dec_token
            self.current_user_name = dec_token["given_name"]
            return dec_token
        #ToDo fix
        except:
            raise

    #Todo
    def load_tokens(self):
        """
        See if there are existing access / refresh tokens available for use

        !! CURRENTLY INSECURE !!
        """
        try:
            with open(os.path.join(MODULE_LOCATION, self.tokens_path), "r") as self.token_file_obj:
                self.token_json = json.load(self.token_file_obj)
                ##ToDo Check for refresh token + validate
                ##ToDo Check for access token  + validate 
                self.id_token_json = jwt.decode(self.token_json["id_token"], algorithm=self.auth0_algorithm, options={"verify_signature": False})   
        except Exception as err:
            print("[-] Problem opening token save file %s"%(err))

    #Todo
    def save_tokens(self):
        """
        Save tokens for use in 
        """
        if self.id_token_json:
            try:
                with open(os.path.join(MODULE_LOCATION, self.tokens_path), "w") as self.token_file_obj:
                    json.dump(self.token_json, self.token_file_obj)
                    print("[+] Saved tokens to %s"%(os.path.join(MODULE_LOCATION, self.tokens_path)))
            except Exception as err:
                print("[-] Problem saving token save file %s"%(err))

    #Todo
    def refresh_token(self):
        """
        Use saved refresh token to request new access token
        """
        refresh_token = self.token_json.get("refresh_token", None)

        if not refresh_token:
            print("[-] No refresh token found")
            return None
        
        ##Use refresh token to get a new access token
        refresh_payload = {"grant_type" : "refresh_token",
                           "client_id"  : self.auth0_client_id,
                           "client_secret" : self.auth0_secret,
                           "refresh_token" : refresh_token}
    
        try:
            resp = requests.post("https://%s/oauth/token"%(self.auth0_domain), data=refresh_payload)
            refresh_token_json = resp.json()

            print("[*] Refresh token response:")
            print(refresh_token_json)    

            self.token_json["access_token"] = refresh_token_json["access_token"]
            ## Todo expiresin

        except Exception as err:
            print("[-] Error calling the token refresh endpoint at https://%s/oauth/token - %s"%(self.auth0_domain, err))
            raise
            return None
        
        print("[*] New Access Token:")
        self.pp.pprint(self.token_json["access_token"])

        ##Save new token
        self.save_tokens()

        return self.token_json["access_token"]

    def get_device_code(self):
        """
        """
        ##Request device code from the configured endpoint
        resp = requests.post("https://%s/oauth/device/code"%(self.auth0_domain), data=self.device_code_data)

        ##Check response for non-HTTP 200 response
        if resp.status_code != 200:
            return -1
        
        self.device_code_json = resp.json()
        print(self.device_code_json)
        return self.device_code_json


if __name__ == "__main__":
    CA = CLIAuth(AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_SECRET)
    CA()