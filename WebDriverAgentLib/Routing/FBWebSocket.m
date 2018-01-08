//
//  FBWebSocket.m
//  WebDriverAgentLib
//
//  Created by Manish Kumar Patwari on 08/01/18.
//  Copyright © 2018 Facebook. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "FBWebSocket.h"

#import <RoutingHTTPServer/RoutingConnection.h>
#import <RoutingHTTPServer/RoutingHTTPServer.h>

#import "FBCommandHandler.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "XCUIDevice+FBHelpers.h"
#import <SocketIO/SocketIO-Swift.h>
static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";

@interface FBSocketConnection : RoutingConnection
@end

@implementation FBSocketConnection

- (void)handleResourceNotFound
{
  [FBLogger logFmt:@"Received request for %@ which we do not handle", self.requestURI];
  [super handleResourceNotFound];
}

@end


@interface FBWebSocket ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
@property (nonatomic, strong) RoutingHTTPServer *server;
@property (atomic, assign) BOOL keepAlive;
@property (nonatomic, strong) SocketManager *manager;
@end

@implementation FBWebSocket

+ (NSArray<Class<FBCommandHandler>> *)collectCommandHandlerClasses
{
  NSArray *handlersClasses = FBClassesThatConformsToProtocol(@protocol(FBCommandHandler));
  NSMutableArray *handlers = [NSMutableArray array];
  for (Class aClass in handlersClasses) {
    if ([aClass respondsToSelector:@selector(shouldRegisterAutomatically)]) {
      if (![aClass shouldRegisterAutomatically]) {
        continue;
      }
    }
    [handlers addObject:aClass];
  }
  return handlers.copy;
}

- (void)startSocket
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  [self startWebSocket];
  
  self.keepAlive = YES;
  NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
  while (self.keepAlive &&
         [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
}

- (void)startWebSocket
{
  NSURL *serverURL = [[NSURL alloc] initWithString:@"http://localhost:8000"];
  self.manager = [[SocketManager alloc] initWithSocketURL:serverURL config:nil];
  SocketIOClient *clientSocket = self.manager.defaultSocket;
  
  [clientSocket on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
    NSLog(@"socket connected");
    [clientSocket emit:@"hello" with: [[NSArray alloc] init]];
  }];
  
  [clientSocket connect];
  
  self.server = [[RoutingHTTPServer alloc] init];
  [self.server setRouteQueue:dispatch_get_main_queue()];
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  [self.server setConnectionClass:[FBSocketConnection self]];
  
  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];
  
  NSRange serverPortRange = FBConfiguration.bindingPortRange;
  NSError *error;
  BOOL serverStarted = NO;
  
  for (NSUInteger index = 0; index < serverPortRange.length; index++) {
    NSInteger port = serverPortRange.location + index;
    [self.server setPort:(UInt16)port];
    
    serverStarted = [self attemptToStartSocket:self.server onPort:port withError:&error];
    if (serverStarted) {
      break;
    }
    
    [FBLogger logFmt:@"Failed to start web server on port %ld with error %@", (long)port, [error description]];
  }
  
  if (!serverStarted) {
    [FBLogger logFmt:@"Last attempt to start web server failed with error %@", [error description]];
    abort();
  }
  [FBLogger logFmt:@"%@http://%@:%d%@", FBServerURLBeginMarker, [XCUIDevice sharedDevice].fb_wifiIPAddress ?: @"localhost", [self.server port], FBServerURLEndMarker];
}

- (void)stopSocket
{
  [FBSession.activeSession kill];
  if (self.server.isRunning) {
    [self.server stop:NO];
  }
  self.keepAlive = NO;
}

- (BOOL)attemptToStartSocket:(RoutingHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
{
  server.port = (UInt16)port;
  NSError *innerError = nil;
  BOOL started = [server start:&innerError];
  if (!started) {
    if (!error) {
      return NO;
    }
    
    NSString *description = @"Unknown Error when Starting server";
    if ([innerError.domain isEqualToString:NSPOSIXErrorDomain] && innerError.code == EADDRINUSE) {
      description = [NSString stringWithFormat:@"Unable to start web server on port %ld", (long)port];
    }
    return
    [[[[FBErrorBuilder builder]
       withDescription:description]
      withInnerError:innerError]
     buildError:error];
  }
  return YES;
}

- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses
{
  for (Class<FBCommandHandler> commandHandler in commandHandlerClasses) {
    NSArray *routes = [commandHandler routes];
    for (FBRoute *route in routes) {
      [self.server handleMethod:route.verb withPath:route.path block:^(RouteRequest *request, RouteResponse *response) {
        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
                                       routeRequestWithURL:request.url
                                       parameters:request.params
                                       arguments:arguments ?: @{}
                                       ];
        
        [FBLogger verboseLog:routeParams.description];
        
        @try {
          [route mountRequest:routeParams intoResponse:response];
        }
        @catch (NSException *exception) {
          [self handleException:exception forResponse:response];
        }
      }];
    }
  }
}

- (void)handleException:(NSException *)exception forResponse:(RouteResponse *)response
{
  if ([self.exceptionHandler handleException:exception forResponse:response]) {
    return;
  }
  id<FBResponsePayload> payload = FBResponseWithErrorFormat(@"%@\n\n%@", exception.description, exception.callStackSymbols);
  [payload dispatchWithResponse:response];
}

- (void)registerServerKeyRouteHandlers
{
  [self.server get:@"/health" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"I-AM-ALIVE"];
  }];
  
  [self.server get:@"/wda/shutdown" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"Shutting down"];
    [self.delegate webSocketDidRequestShutdown:self];
  }];
  
  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
