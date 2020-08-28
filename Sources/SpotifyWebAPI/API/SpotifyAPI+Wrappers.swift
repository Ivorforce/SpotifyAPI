import Foundation
import Combine
import Logger

extension SpotifyAPI {
    
    /**
     Makes a request to the Spotify Web API. You should usually
     not need to call this method youself.
     All requests to endpoints other than those for authorizing
     the app and retrieving/refreshing the tokens call through
     to this method.
     
     **Note: There is an overload that accepts an instance of a**
     **type conforming to Encodable for the body parameter.**
     Only use this method if the body cannot be encoded to `Data`
     using a `JSONEncoder`.
     
     The refresh token will be refreshed automatically if needed
     before the request is made.
     
     If you are making a get request, use
     `self.getRequest(path:queryItems:requiredScopes:responseType:)`
     instead, which is a thin wrapper that calls though to this method.
     
     The base url that the path and query items are appended to is
     ```
     "https://api.spotify.com/v1"
     ```
     
     A closure that accepts the access token must be used
     to make the headers because the access token will not
     be accessed until a call to `self.refreshAccessToken(onlyIfExpired: true)`
     is made. This function may return a new access token, which will then
     be used in the headers.
     
     - Parameters:
       - path: The path to the endpoint, which will be appended to the
             base url above. Do **NOT** forget the leading forward-slash.
       - queryItems: The URL query items.
       - httpMethod: The http method.
       - makeHeaders: A function that accepts an access token and
             returns a dictionary of headers. See the `Headers`
             enum, which contains convienence methods for making
             headers.
       - bodyData: The body of the request as `Data`.
       - requiredScopes: The scopes required for this endpoint.
     - Returns: The raw data and the url response from the server.
     */
    func apiRequest(
        path: String,
        queryItems: [String : LosslessStringConvertible?],
        httpMethod: String,
        makeHeaders: @escaping (_ accessToken: String) -> [String: String],
        bodyData: Data?,
        requiredScopes: Set<Scope>
    ) -> AnyPublisher<(data: Data, response: URLResponse), Error> {
        
        let endpoint = Endpoints.apiEndpoint(
            path, queryItems: removeIfNil(queryItems)
        )

        // ensure unecessary work is not done converting the
        // body to a string.
        if self.apiRequestLogger.level <= .warning {
            
            self.apiRequestLogger.trace(
                "\(httpMethod) request to \"\(endpoint)\""
            )
            
            if let bodyData = bodyData {
                if let bodyString = String(data: bodyData, encoding: .utf8) {
                    self.apiRequestLogger.trace(
                        "request body:\n\(bodyString)"
                    )
                }
                else {
                    self.apiRequestLogger.warning(
                        "couldn't convert body data to string"
                    )
                }
            }
            
        }
        
        return self.authorizationManager.refreshTokens(
            onlyIfExpired: true, tolerance: 60
        )
        .tryMap { () -> String in
            
            guard let acccessToken = self.authorizationManager.accessToken else {
                throw SpotifyLocalError.unauthorized(
                    "unauthorized: no access token"
                )
            }
            guard self.authorizationManager.isAuthorized(
                for: requiredScopes
            )
            else {
                throw SpotifyLocalError.insufficientScope(
                    requiredScopes: requiredScopes,
                    authorizedScopes: self.authorizationManager.scopes ?? []
                )
            }
            return acccessToken
            
        }
        .flatMap { accessToken in
            
            return URLSession.shared.dataTaskPublisher(
                url: endpoint,
                httpMethod: httpMethod,
                headers: makeHeaders(accessToken),
                body: bodyData
            )
            .mapError { $0 as Error }
            
        }
        .eraseToAnyPublisher()

    }
    
    /**
     Makes a request to the Spotify Web API. You should usually
     not need to call this method youself.
     All requests to endpoints other than those for authorizing
     the app and retrieving/refreshing the tokens call through
     to this method.
     
     The refresh token will be refreshed automatically if needed
     before the request is made.
     
     Use
     `apiRequest(path:queryItems:httpMethod:makeHeaders:bodyData:requiredScopes:)`
     if the body cannot be encoded into `Data` using a `JSONEncoder`.
     
     If you are making a get request, use
     `self.getRequest(path:queryItems:requiredScopes:responseType:)`
     instead, which is a thin wrapper that calls though to this method.
     
     The base url that the path and query items are appended to is
     ```
     "https://api.spotify.com/v1"
     ```
     
     A closure that accepts the access token must be used
     to make the headers because the access token will not
     be accessed until a call to `self.refreshAccessToken(onlyIfExpired: true)`
     is made. This function may return a new access token, which will then
     be used in the headers.
    
     - Parameters:
       - path: The path to the endpoint, which will be appended to the
             base url above. Do **NOT** forget the leading forward-slash.
       - queryItems: The URL query items.
       - httpMethod: The http method.
       - makeHeaders: A function that accepts an access token and
             returns a dictionary of headers. See the `Headers`
             enum, which contains convienence methods for making
             headers.
       - body: The body of the request as a type that conforms to `Decodable`.
       - requiredScopes: The scopes required for this endpoint.
     - Returns: The raw data and the url response from the server.
    */
    func apiRequest<Body: Encodable>(
        path: String,
        queryItems: [String : LosslessStringConvertible?],
        httpMethod: String,
        makeHeaders: @escaping (_ accessToken: String) -> [String: String],
        body: Body?,
        requiredScopes: Set<Scope>
    ) -> AnyPublisher<(data: Data, response: URLResponse), Error> {
        
        do {
            
            let encodedBody = try body.map {
                try JSONEncoder().encode($0)
            }
            
            return self.apiRequest(
                path: path,
                queryItems: queryItems,
                httpMethod: httpMethod,
                makeHeaders: makeHeaders,
                bodyData: encodedBody,
                requiredScopes: requiredScopes
            )
            
        } catch {
            return error.anyFailingPublisher(
                (data: Data, response: URLResponse).self
            )
        }
        
    }
    
    
    
    // MARK: - Get Request -
    
    /**
     Makes a get request to the Spotify web API.
     You should not normally need to call this method.
     Automatically refreshes the access token if necessary.
     
     The base url that the path and query items are appended to is
     ```
     "https://api.spotify.com/v1"
     ```
     - Parameters:
       - path: The path to the endpoint, which will be appended to the
             base url above.
       - queryItems: The URL query items.
       - requiredScopes: The scopes required for this endpoint.
       - responseType: The expected response type from the Spotify
             web API.
     - Returns: The raw data and the url response from the server.
     */
    func getRequest(
        path: String,
        queryItems: [String : LosslessStringConvertible?],
        requiredScopes: Set<Scope>
    ) -> AnyPublisher<(data: Data, response: URLResponse), Error> {
        
        return apiRequest(
            path: path,
            queryItems: queryItems,
            httpMethod: "GET",
            makeHeaders: Headers.bearerAuthorization(_:),
            bodyData: nil as Data?,
            requiredScopes: requiredScopes
        )
        
    }
    
   
}