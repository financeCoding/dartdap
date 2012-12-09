
library ldap_connection;

import 'dart:io';
import 'dart:isolate';
import 'dart:scalarlist';
import 'package:logging/logging.dart';
import 'protocol/ldap_protocol.dart';

import 'filter.dart';
import 'ldap_exception.dart';
import 'ldap_result.dart';

class PendingOp {
  LDAPMessage message;
  final Completer  completer = new Completer();

  PendingOp(this.message);


  String toString() => "PendingOp m=${message}";
}


class LDAPConnection {

  String _host;
  int _port;
  String _connectDn = "";
  String _password;

  int _nextMessageId = 1;

  Socket _socket;

  Function onError;


  Queue<PendingOp> outgoingMessageQueue = new Queue<PendingOp>();
  Queue<PendingOp> pendingMessages = new Queue<PendingOp>();

  static const DISCONNECTED = 0;
  static const CONNECTING = 1;
  static const CONNECTED = 2;
  static const BINDING = 3;
  static const BOUND = 4;
  static const CLOSING = 6;

  int _connectionState = DISCONNECTED;


  bool _connected = false;
  bool _startSync = false;

  get connected => _connected;



  LDAPConnection(this._host,this._port,[this._connectDn ,this._password]) {
    connect();
  }

  connect() {
    logger.finest("Creating socket to ${_host}:${_port}");
    _connectionState = CONNECTING;
    _socket = new Socket(_host,_port);

    _socket.onConnect = _connectHandler;
    _socket.onError = _errorHandler;
  }

  /**
   * Bind to LDAP server
   */
  Future<LDAPResult> bind() {
    var b = new BindRequest(_connectDn, _password);
    var m = new LDAPMessage(_nextMessageId++,b);


    _startSync = true;

    // auto connect...
    if( _connectionState  == DISCONNECTED )
      connect();

    // we need to intercep the bind response so we can mark the state as BOUND
    Future<LDAPResult> f = process(m);


    f.then( (LDAPResult r) {
      if( r.resultCode == 0) {
        logger.fine("LDAP Bind OK");
        _connectionState = BOUND;
        _startSync = false;
      }

    });


    return f;
  }


  /**
   * Search Request
   */

  Future<SearchResult> search(String baseDN, Filter filter, List<String> attributes) {
    var sr = new SearchRequest(baseDN,filter, attributes);
    var m = new LDAPMessage(_nextMessageId++, sr);

    return process(m);
  }

  _errorHandler(e) {
    logger.severe("LDAP Error ${e}");
    var ex = new LDAPException(e.toString());
    if( onError != null) {
      onError(ex);
    }
    else {
      logger.warning("No error handler set for LDAPConnection");
      throw ex;
    }
  }

  Future process(LDAPMessage m) {
    var op = new PendingOp(m);
    outgoingMessageQueue.add( op);
    sendPendingMessage();
    return op.completer.future;
  }

  sendPendingMessage() {
    logger.fine("Send pending messages");

    if( _connectionState == CONNECTING ) {
      logger.finest("Not connected or ready. Yielding");
      return;
    }

    while( messagesToSend() ) {
      var op = outgoingMessageQueue.removeFirst();
      _sendMessage(op);
    }
  }

  bool messagesToSend() {
    //logger.fine("Message check. oql=${outgoingMessageQueue.length} ");
    if( ! pendingMessages.isEmpty ) {
      var m = pendingMessages.first.message;
      //logger.finest("pendign check - message = ${m}");
      if( m.protocolTag == BIND_REQUEST)
        return false;
    }
    if( outgoingMessageQueue.isEmpty)
      return false;


    return true;
  }

  _sendMessage(PendingOp op) {
    logger.fine("Sending message ${op.message}");
    var l = op.message.toBytes();
    var b_read = _socket.writeList(l, 0,l.length);
    // todo: check length of bytes read
    pendingMessages.add(op);
  }

  // bool _bindPending() => sentMessage

  _connectHandler() {
    logger.fine("Connected");
    _connectionState = CONNECTED;

    _socket.onData = _dataHandler;

    sendPendingMessage();
  }

  /**
   * Check for pending ops..
   *
   * Close the LDAP connection.
   *
   * Pending operations will be allowed to finish, unless immediate = true
   */

  close({bool immediate:false}) {
    if( immediate ) {
      _doClose();
    }
    else {
      new Timer.repeating(1000, (Timer t) {
        if( _tryClose() )
          t.cancel();
      });
    }

    _socket.close();
    _connected = false;

  }

  bool _tryClose() {
    if( pendingMessages.isEmpty && outgoingMessageQueue.isEmpty) {
      _doClose();
      return true;
    }
    logger.finest("close waiting for queue to drain");
    print("pending $pendingMessages  out=$outgoingMessageQueue");
    return false;
  }

  _doClose() {
    _socket.close();
    _connected = false;
  }


  _dataHandler() {
    int available = _socket.available();
    while( available > 0 ) {
      var buffer = new Uint8List(available);

      var count = _socket.readList(buffer,0, buffer.length);
      logger.finest("read ${count} bytes");
      //var s = listToHexString(buffer);
      //logger.finest("Bytes read = ${s}");


      var tempBuf = buffer;
      int bcount = tempBuf.length;

      while( bcount > 0) {
        int  bytesRead = _handleMessage(tempBuf);
        bcount = bcount - bytesRead;
        if(bcount > 0 )
          tempBuf = new Uint8List.view( tempBuf.asByteArray(bytesRead,bcount));
      }

      sendPendingMessage();
      available = _socket.available();
    }
    logger.finest("No socket data available");
  }

  int _handleMessage(Uint8List buffer) {
    // todo: While more totalEncodedBytes
    var m = new LDAPMessage.fromBytes(buffer);
    logger.fine("Recieved LDAP message ${m} byte length=${m.messageLength}");

    var rop = ResponseHandler.handleResponse(m);

    if( rop is SearchResultEntry ) {
      handleSearchOp(rop);
    }
    else if( rop is SearchResultDone ) {
      logger.fine("Finished Search Results = ${searchResults}");
      searchResults.ldapResult = rop.ldapResult;
      var op = pendingMessages.removeFirst();
      op.completer.complete(searchResults);
      searchResults = new SearchResult();
    }

    else {
      var op = pendingMessages.removeFirst();
      op.completer.complete(rop.ldapResult);
    }
    return m.messageLength;
  }

  SearchResult searchResults = new SearchResult();

  void handleSearchOp(SearchResultEntry r) {
    logger.fine("Adding result ${r} ");
    searchResults.add(r.searchEntry);
  }

}