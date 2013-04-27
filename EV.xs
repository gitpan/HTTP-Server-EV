#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "EVAPI.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <errno.h>


#define MAX_LISTEN_PORTS 24
#define ALLOCATE 1 
#define BUFFERS_SIZE 4100

#define MAX_DATA 2048 //max multipart form fields
#define SOCKREAD_BUFSIZ 8192
#define BODY_CHUNK_BUFSIZ 51200 //multipart form field value limited by one chunk size. Also it's file receiving buffer - file piece stored on disc(and on_file_write_called) when BODY_CHUNK_BUFSIZ bytes received
#define MAX_URLENCODED_BODY 102400


// parser state. Don't change!
#define REQ_DROPED_BY_PERL -1

#define REQ_METHOD 1
#define URL_STRING 2

#define HEADERS_NOTHING 3

#define HEADER_NAME 4
#define HEADER_VALUE 5

#define BODY_URLENCODED 6

#define BODY_M_NOTHING 7
#define BODY_M_FILE 8
#define BODY_M_DATA 9

#define BODY_M_HEADERS 10
#define BODY_M_HEADERS_NAME 11
#define BODY_M_HEADERS_FILENAME 12


// #ifdef WIN32
	// #include <windows.h>
	// #define errno WSAGetLastError()
// #endif
		
		


struct port_listener {
	ev_io io;
	
	SV* callback; 
	SV* pre_callback;
	SV* error_callback;
	
	float timeout;
};

struct req_state {
	ev_io io;
	struct port_listener *parent_listener;
	
	ev_tstamp timeout;
	ev_timer timer;
	
	
	int saved_to;
	
	char reading;
	
	int content_length;
	int total_readed;
	
	
	int headers_end_match_pos;
	int headers_sep_match_pos;
	
	int multipart_name_match_pos;
	int multipart_filename_match_pos;
	
	int multipart_data_count;
	
	// Socketread buffer
	char *buffer;
	int readed;
	int buffer_pos;
	
	// Two bufers for http headers name and value, for request addres and multipart forminput name, filename
	char *buf;
	int buf_pos;
	
	char *buf2;
	int buf2_pos;
	
	
	
	char *boundary;
	int match_pos;
	
	//buffer for text input data and file chunks
	char *body_chunk;
	int body_chunk_pos;
	
	
	SV* tmpfile_obj;
	
	
	HV* headers;
	
	HV* post;
	HV* post_a;
	
	HV* file;
	HV* file_a;
	
	HV* rethash;
	SV* req_obj; //ref to rethash
};


///// Work with tempfiles

	static SV* create_tmp (struct req_state *state){
		HV* hash = newHV();
		state->tmpfile_obj = sv_bless( newRV_noinc((SV*) hash) ,   gv_stashpv( "HTTP::Server::EV::MultipartFile", GV_ADD) );
		
		hv_store(hash, "size", 4, (SV*) newSViv(0) , 0);
		
		SV* filename =newSVpv(state->buf2, state->buf2_pos);
		SvUTF8_on(filename);
		hv_store(hash, "name" , 4 , filename , 0);
		
		SV* parent = newSVsv(state->req_obj);
		sv_rvweaken(parent);
		hv_store(hash, "parent_req", 10, parent , 0);
		
		state->body_chunk_pos = 0;
		
		dSP;
		ENTER;
		SAVETMPS;

		PUSHMARK (SP);
		XPUSHs (state->tmpfile_obj);

		PUTBACK;
			call_method ("_new", G_DISCARD);
		// PUTBACK;
		FREETMPS;
		LEAVE;
		
		return state->tmpfile_obj;
	}
	
	
	static void tmp_putc (struct req_state *state, char chr){
		
		state->body_chunk[state->body_chunk_pos] = chr;
		state->body_chunk_pos++;
		
		
		if(state->body_chunk_pos >= BODY_CHUNK_BUFSIZ){
			dSP;
			ENTER;
			SAVETMPS;

			PUSHMARK (SP);
			XPUSHs (state->tmpfile_obj);
			XPUSHs ( sv_2mortal(
				newSVpvn( state->body_chunk, BODY_CHUNK_BUFSIZ-2 )
			));
			
			PUTBACK;
				call_method ("_flush", G_DISCARD);
			// PUTBACK;
			FREETMPS;
			LEAVE;
			
			state->body_chunk[0] = state->body_chunk[BODY_CHUNK_BUFSIZ-2];
			state->body_chunk[1] = state->body_chunk[BODY_CHUNK_BUFSIZ-1];
			state->body_chunk_pos = 2;
		}
	}
	
	
	static char tmp_close(struct req_state *state){
		char wait = 0; // reports to main cycle if it need to return and wait for IO complete
		
		
		if(state->body_chunk_pos > 2){
			wait = 1; 
		
			dSP;
			ENTER;
			SAVETMPS;

			PUSHMARK (SP);
			XPUSHs (state->tmpfile_obj);
			XPUSHs ( sv_2mortal(
				newSVpvn( state->body_chunk, state->body_chunk_pos-2 )
			));
			
			PUTBACK;
				call_method ("_flush", G_DISCARD);
			// PUTBACK;
			FREETMPS;
			LEAVE;
		};
		
		
		dSP;
		ENTER;
		SAVETMPS;

		PUSHMARK (SP);
		XPUSHs (state->tmpfile_obj);

		PUTBACK;
			call_method ("_done", G_VOID);
		// PUTBACK;
		FREETMPS;
		LEAVE;
		
		return wait;
	}
	
	

///// parsers state saving and memory allocating /////
struct req_state* *accepted;
static int accepted_pos = 0;

static int *accepted_stack;
static int accepted_stack_pos = 0;

static int accepted_allocated = 0;

struct req_state * alloc_state (){

	// alocate memory if needed
	if( ! accepted_stack_pos ){ 
		int i = accepted_allocated;
		
		accepted_allocated += ALLOCATE;

		if(!( 
				( accepted = (struct req_state **) realloc(accepted,  accepted_allocated * sizeof(struct req_state*) ) ) && 
				( accepted_stack = (int *) realloc(accepted_stack,  accepted_allocated * sizeof(int) ) )
			)
		  ){ return NULL; }

		
		// push in stack list of free to use elements
		for(; i < accepted_allocated; i++){ 
			if(!( accepted[i] = (struct req_state *) malloc( sizeof(struct req_state) ) )){ return NULL; }
			
			
			if(!( accepted[i]->buffer = (char *) malloc(SOCKREAD_BUFSIZ * sizeof(char) ) )){ return NULL; }
			
			if(!( accepted[i]->buf = (char *) malloc(BUFFERS_SIZE * sizeof(char) ) )){ return NULL; }
			if(!( accepted[i]->buf2 = (char *) malloc(BUFFERS_SIZE * sizeof(char) ) )){ return NULL; }
			
			if(!( accepted[i]->boundary = (char *) malloc(BUFFERS_SIZE * sizeof(char) ) )){ return NULL; }
			if(!( accepted[i]->body_chunk = (char *) malloc(BODY_CHUNK_BUFSIZ * sizeof(char)) )){ return NULL; }
			
			
			accepted_stack[accepted_stack_pos] = i;
			accepted_stack_pos++;
		}
	}
	
	//get element from stack
	
	--accepted_stack_pos;
	struct req_state *state = accepted[ accepted_stack[accepted_stack_pos] ];
	state->saved_to = accepted_stack[accepted_stack_pos]; 
	
	//set fields to defaults
	state->buffer_pos = 0;
	state->body_chunk_pos = 0;
	
	memset(state->buf , 0 , BUFFERS_SIZE );
	state->buf_pos = 0 ;
	
	memset(state->buf2 , 0 , BUFFERS_SIZE );
	state->buf2_pos = 0 ;
	
	memset(state->boundary , 0 , BUFFERS_SIZE );
	state->match_pos = 0;
	
	state->reading = REQ_METHOD;
	
	state->content_length = 0;
	state->total_readed = 0;
	
	state->headers_end_match_pos = 0;
	state->headers_sep_match_pos = 0;
	
	
	//state->get = newHV();
	//state->get_a = newHV();
	
	state->multipart_name_match_pos = 0;
	state->multipart_filename_match_pos = 0;
	
	state->multipart_data_count = 0;
	
	state->headers = newHV();
	
	state->post = newHV();
	state->post_a = newHV();
	
	state->file = newHV();
	state->file_a = newHV();
	
	state->rethash = newHV();
	
	hv_store(state->rethash, "stack_pos", 9, (SV*) newSViv(state->saved_to) , 0);
	
	hv_store(state->rethash, "post" , 4, newRV_noinc((SV*)state->post), 0);
	hv_store(state->rethash, "post_a" , 6, newRV_noinc((SV*)state->post_a), 0);
	hv_store(state->rethash, "file" , 4, newRV_noinc((SV*)state->file), 0);
	hv_store(state->rethash, "file_a" , 6, newRV_noinc((SV*)state->file_a), 0);
	hv_store(state->rethash, "headers" , 7, newRV_noinc((SV*)state->headers), 0);
	
	state->req_obj = sv_bless( 
			newRV_noinc((SV*)state->rethash) ,
			gv_stashpv( "HTTP::Server::EV::CGI", GV_ADD) 
		);
	

	
	return state; // return pointer to allocated struct
}


static void free_state(struct req_state *state){
	SvREFCNT_dec(state->req_obj);
	accepted_stack[accepted_stack_pos] = state->saved_to;
	accepted_stack_pos++;
}

static void push_to_hash(HV* hash, char *key, int  klen, SV* data){
		SV** arrayref;
		if(arrayref = hv_fetch(hash, key, klen, 0)){
			av_push((AV*) SvRV( *arrayref ) , data);
			SvREFCNT_inc(data);
		} else {
			hv_store(hash, key, klen, newRV_noinc((SV*) av_make(1, &data )  )  , 0);
		}
	}

//////////////////////////////

///// Stream parsing /////

static int search(char input, char *line, int *match_pos ){
	if(input == line[ *match_pos ]){
		(*match_pos)++;
		
		if(! line[ *match_pos ] ){
			*match_pos = 0;
			return 1;
		}
	}else{
		*match_pos = 0;
	};
	return 0;
}


///////////////////////

//// Callbacks ////
static void init_cgi_obj(struct req_state *state){
	dSP;
	ENTER;
	SAVETMPS;
	PUSHMARK(SP);
	XPUSHs( state->req_obj );
	PUTBACK;
	
	call_method ("new", G_DISCARD);
	
	FREETMPS;
	LEAVE;
};


static void call_perl(struct req_state *state){
	hv_store(state->rethash, "received", 8, newSViv(1) , 0);
	
	ev_timer_stop(EV_DEFAULT, &(state->timer) ); 
	
	dSP;
	ENTER;
	SAVETMPS;
	PUSHMARK(SP);
	XPUSHs( state->req_obj );
	PUTBACK;
	
	call_sv(state->parent_listener->callback, G_VOID);
	free_state( state );
	
	
	FREETMPS;
	LEAVE;
};

static void call_pre_callback(struct req_state *state){
	init_cgi_obj(state);
	
	dSP;
	ENTER;
	SAVETMPS;
	PUSHMARK(SP);
	XPUSHs( state->req_obj );
	PUTBACK;
	
	
	call_sv(state->parent_listener->pre_callback, G_VOID);
	
	FREETMPS;
	LEAVE;
};

static void drop_conn (struct req_state *state, struct ev_loop *loop){
	
	if (state->reading >= BODY_M_NOTHING || state->reading == REQ_DROPED_BY_PERL){
		dSP;
		ENTER;
		SAVETMPS;
		PUSHMARK(SP);
		XPUSHs( state->req_obj );
		PUTBACK;
		
		call_sv(state->parent_listener->error_callback, G_VOID);
		
		FREETMPS;
		LEAVE;
	}
	
	ev_io_stop(loop, &(state->io) ); 
	ev_timer_stop(EV_DEFAULT, &(state->timer) ); 
	
	close( state->io.fd );
	
	ev_io_start(EV_DEFAULT, &( state->parent_listener->io) ); 	
	free_state(state);
}
//////////

static void timer_cb(struct ev_loop *loop, ev_timer *w, int revents) {
	drop_conn( (struct req_state *) w->data , loop);
}


static void handler_cb (struct ev_loop *loop, ev_io *w, int revents){
	struct req_state *state = (struct req_state *)w;
	
	struct sockaddr *buf;
	int bufsize = sizeof(struct sockaddr);
	
	// yes, this is goto shit
	if(state->reading == REQ_DROPED_BY_PERL)
		goto drop_conn;
	
	if(!state->buffer_pos){ //called to read new data
		if( ( state->readed = PerlSock_recvfrom(w->fd, state->buffer, SOCKREAD_BUFSIZ,  0, buf, &bufsize) ) <= 0 ){
			// connection closed or error
			drop_conn:
				drop_conn(state, loop);
				return;
		}
	} //else - woken up from suspending. Process existent data
	//reset timeout
	if (state->timeout != 0.)
		ev_timer_again(loop, &(state->timer));
	
	//write only shit...
	for(; state->buffer_pos < state->readed ; state->buffer_pos++ ){
		
		if(state->reading == REQ_DROPED_BY_PERL)
			goto drop_conn;
			
		if(state->reading & (1 << 7))// 7 bit set - suspended
			return;
		
		// Read req string
		if(state->reading <= HEADERS_NOTHING) {
			if( search( state->buffer[state->buffer_pos], "\r\n", &state->headers_end_match_pos ) ){
				
	
				if(!state->buf2_pos){ goto drop_conn;} //no url
				
				// save to headers hash
				hv_store(state->headers, "REQUEST_METHOD" , 14 , newSVpv(state->buf, state->buf_pos) , 0);
				hv_store(state->headers, "REQUEST_URI" , 11 , newSVpv(state->buf2, state->buf2_pos) , 0);
				
				state->reading = HEADER_NAME;
				state->buf_pos = 0;
				state->buf2_pos = 0;
			}
			
			if(state->reading == URL_STRING){ // reading url string
				if(state->buffer[state->buffer_pos] == ' '){
					state->reading = HEADERS_NOTHING;
				}
				else{
					state->buf2[ state->buf2_pos ] = state->buffer[state->buffer_pos];
					state->buf2_pos++;
					if(state->buf2_pos >= BUFFERS_SIZE){ goto drop_conn; }
				}
			}
			else if(state->reading == REQ_METHOD) { // reading request method
				if(state->buffer[state->buffer_pos] == ' '){ //end of reading request method
					
					state->reading = URL_STRING;
				}else{
					state->buf[ state->buf_pos ] = state->buffer[state->buffer_pos];
					state->buf_pos++;
					if(state->buf_pos >= BUFFERS_SIZE){ goto drop_conn; }
				}
			}
			
		}
		// read headers
		else if(state->reading <= HEADER_VALUE){
			if( search( state->buffer[state->buffer_pos], "\r\n", &state->headers_end_match_pos ) ){
				
				// end of headers
				if(state->buf_pos == 1){
					SV** hashval; 
					char *str;
					
					if(! (hashval = hv_fetch(state->headers, "REQUEST_METHOD" , 14 , 0) ) ){ goto drop_conn;} // goto will never happen...
					str = SvPV_nolen(*hashval);
					
					// method POST
					if( strEQ("POST", str) ){
						
						if(! (hashval = hv_fetch(state->headers, "HTTP_CONTENT-LENGTH" , 19 , 0) ) ){ goto drop_conn;}
						str = SvPV_nolen(*hashval);
						
						state->content_length = atoi(str);
						
						if(! (hashval = hv_fetch(state->headers, "HTTP_CONTENT-TYPE" , 17 , 0) ) ){ goto drop_conn;} // goto will never happen...
						STRLEN len;
						str = SvPV(*hashval, len);
						
						// multipart post data
						if((len > 3) && (str[0]=='m' || str[0]=='M') && (str[1]=='u' || str[1]=='U') && (str[2]=='l' || str[2]=='L') ){ 
							int i; int pos = 2;
							char reading_boundary = 0;
							state->boundary[0] = state->boundary[1] = '-';
							
							for(i = 0; i < len; i++){
								if(reading_boundary){
									state->boundary[pos] = str[i];
									pos++;
								}else
								if(str[i] == '='){ reading_boundary = 1; }
							}
							if( (pos < 2) || !reading_boundary ){ goto drop_conn;}
							
							state->reading = BODY_M_NOTHING;
							call_pre_callback(state);
						}
						// urlencoded data
						else{ 
							if(state->content_length > MAX_URLENCODED_BODY){ goto drop_conn;};
							
							state->reading = BODY_URLENCODED;
							hv_store(state->rethash, "REQUEST_BODY" , 12 , newSV(1024) , 0);
						}
						
						//printf("Boundary: %s \nLen: %d", state->boundary, state->content_length);
						goto end_headers_reading;
					}
					// method GET
					else {
						init_cgi_obj(state);
						call_perl(state);
						ev_io_stop(loop, w); 
						break;
					}
					
				}
				
				state->reading = HEADER_NAME;
				if(state->buf2_pos > 0){state->buf2_pos -= 1;}  // because we don`t need "\r" in value
				
				//save to headers hash
				SV* val = newSVpv(state->buf2, state->buf2_pos);
				SvREFCNT_inc(val);
				
				hv_store(state->headers, state->buf , state->buf_pos , val , 0);
				
				
				char uc_string[BUFFERS_SIZE+6];
				
				uc_string[0]='H';
				uc_string[1]='T';
				uc_string[2]='T';
				uc_string[3]='P';
				uc_string[4]='_';
				
				int i = 0;
				for(; i < state->buf_pos; i++){
					uc_string[i+5] = toUPPER( state->buf[i] );
				}
				
				hv_store(state->headers, uc_string , state->buf_pos+5 , val , 0);
				
				
				end_headers_reading: 
				state->buf_pos = 0;
				state->buf2_pos = 0;
				
				continue;
			}
			if( search( state->buffer[state->buffer_pos], ": ", &state->headers_sep_match_pos) ){
				state->buf_pos -= 1; // because we don`t need ":" in name
				state->reading = HEADER_VALUE;
				continue;
			}
			
			if(state->reading == HEADER_NAME){ // read header name to buf
				state->buf[ state->buf_pos ] = state->buffer[state->buffer_pos];
				state->buf_pos++;
				if(state->buf_pos >= BUFFERS_SIZE){ goto drop_conn; }
			}
			else{  // read header value to buf2
				state->buf2[ state->buf2_pos ] = state->buffer[state->buffer_pos];
				state->buf2_pos++;
				if(state->buf2_pos >= BUFFERS_SIZE){ goto drop_conn; }
			}
		}
		// read urlencoded body
		else if(state->reading == BODY_URLENCODED ){
			SV** hashval; 
			if(! (hashval = hv_fetch(state->rethash, "REQUEST_BODY" , 12 , 0) ) ){goto drop_conn;} // goto will never happen...
			int bytes_to_read = state->readed - state->buffer_pos;
			
			if( (state->total_readed + bytes_to_read) > state->content_length ){
				bytes_to_read = state->content_length - state->total_readed;
			}
			
			sv_catpvn(*hashval, &state->buffer[state->buffer_pos] , bytes_to_read );
			state->total_readed += bytes_to_read;
			
			if( state->total_readed >= state->content_length ){
				init_cgi_obj(state);
				call_perl(state);
				ev_io_stop(loop, w); 
				return;
			};
			break;
		}
		//////////////////// Reading multipart //////////////////////////
		else {
			state->total_readed++;
			//reading multipart data or file
			if(state->reading < BODY_M_HEADERS){
			
				if(state->buffer[state->buffer_pos] == state->boundary[state->match_pos]){
					state->match_pos++;
					
					if(! state->boundary[state->match_pos] ){ //matched all boundary
						state->match_pos = 0;
						//printf("\nBoundary matched\n");
								
								if(state->reading == BODY_M_DATA){
									SV* data =  newSVpv(
										state->body_chunk_pos-2 > 0 ? state->body_chunk : "", 
										state->body_chunk_pos-2 );
									SvUTF8_on(data);
									
									hv_store(state->post, state->buf , state->buf_pos , data , 0) ;
									push_to_hash(state->post_a , state->buf , state->buf_pos, data);
									
									state->body_chunk_pos = 0;
									state->buf_pos = 0;
								}
								else if(state->reading == BODY_M_FILE){
								//end of file reading
									state->buf_pos = 0;
									state->buf2_pos = 0;
									
									state->reading = BODY_M_HEADERS;
									
									// processing always suspended after tmp_close call
									if(tmp_close(state)) //tmp_close returns TRUE if needs wait for IO 
										return;
								}
								
								state->reading = BODY_M_HEADERS;
								
					}
				}
				else{
					// reading form input
					if(state->reading == BODY_M_DATA){
						if(state->match_pos){
							int bound_i;
									
							for(bound_i = 0; bound_i < state->match_pos; bound_i++){
								state->body_chunk[state->body_chunk_pos] = state->boundary[bound_i];
								state->body_chunk_pos++;
										
								if(state->body_chunk_pos >= BODY_CHUNK_BUFSIZ){ goto drop_conn; }
							}		
						}
								
						state->body_chunk[state->body_chunk_pos] = state->buffer[state->buffer_pos];
						state->body_chunk_pos++;		
						if(state->body_chunk_pos >= BODY_CHUNK_BUFSIZ){ goto drop_conn; }
								
					}
					// reading form file
					else if(state->reading == BODY_M_FILE){
						if(state->match_pos){ //append false boundary match
							int bound_i = 0;
							for(; bound_i < state->match_pos; bound_i++){
								tmp_putc(state, state->boundary[bound_i]);
							};
						};
							

						//append char
						tmp_putc(state, state->buffer[state->buffer_pos]);
					};
							
					state->match_pos = 0;
				}
			}
			// Reading multipart headers
			else if(state->reading >= BODY_M_HEADERS){
					//buf - name
					//buf2 - filename
					
				// searching for name
				if(search(state->buffer[state->buffer_pos], " name=\"", &state->multipart_name_match_pos) && !(state->buf_pos)){
					state->reading = BODY_M_HEADERS_NAME;
					//printf("Name match\n");
					continue;
				}
				// reading name
				else if(state->reading == BODY_M_HEADERS_NAME){
					if(state->buffer[state->buffer_pos] == '"'){
						state->reading = BODY_M_HEADERS;
						continue;
					}else{
						state->buf[ state->buf_pos ] = state->buffer[state->buffer_pos];
						state->buf_pos++;
						if(state->buf_pos >= BUFFERS_SIZE){ goto drop_conn; }
					}
				}
				
				// searching for filename
				else if(!(state->buf2_pos) && search(state->buffer[state->buffer_pos], "filename=\"", &state->multipart_filename_match_pos)){
					state->reading = BODY_M_HEADERS_FILENAME;
					//printf("FileName match\n");
					continue;
				}
				// reading filename
				else if(state->reading == BODY_M_HEADERS_FILENAME){
					if(state->buffer[state->buffer_pos] == '"'){
						state->reading = BODY_M_HEADERS;
						continue;
					}else{
						state->buf2[ state->buf2_pos ] = state->buffer[state->buffer_pos];
						state->buf2_pos++;
						if(state->buf2_pos >= BUFFERS_SIZE){ goto drop_conn; }
					}
				};
				
						
				// searching for end of headers
				if(search( state->buffer[state->buffer_pos], "\r\n\r\n", &state->headers_end_match_pos) ){

					if( 
						state->reading == BODY_M_HEADERS_NAME ||
						state->reading == BODY_M_HEADERS_FILENAME //||
					//	!state->buf_pos // Did some browsers may send form fields with empty name?
					){ goto drop_conn; } //malformed multipart headers
						
					//printf("\nEnd of fileheader matched\n");	
					
					
					if(state->buf2_pos){//filename defined 
						state->reading =  BODY_M_FILE;
						
						// printf("create tmp\n");
						SV* file = create_tmp(state);
						hv_store(state->file, state->buf , state->buf_pos , file , 0);
						push_to_hash(state->file_a, state->buf, state->buf_pos, file );
					}else{
						state->reading =  BODY_M_DATA;
					}
					
					
					if(state->multipart_data_count > MAX_DATA){ goto drop_conn; }
					state->multipart_data_count++;
						
					continue;
				}
			}
			
			//end of stream
			if( state->total_readed >= state->content_length ){ 
				if( state->reading == BODY_M_HEADERS || state->reading == BODY_M_NOTHING ){
					// printf("call perl\n");
					call_perl(state);
					ev_io_stop(loop, w); 
					return;
				}
				goto drop_conn;
			};
		}
	}
	
	state->buffer_pos = 0;
}

static void listen_cb (struct ev_loop *loop, ev_io *w, int revents){	
		struct port_listener *listener = (struct port_listener *)w;
		
		int accepted_socket;
		struct sockaddr_in cliaddr;
		int addrlen = sizeof(cliaddr);
		
		if( ( accepted_socket = accept( w->fd , (struct sockaddr *) &cliaddr, &addrlen ) ) == -1 )
		{ 
			// printf("error %d %d\n", errno, EAGAIN);
			if(errno == EAGAIN){ // event received by another child process
				return;
			}
			warn("HTTP::Server::EV ERROR: Can`t accept connection. Run out of open file descriptors! Listening stopped until one of the server connection will be closed!");
			
			ev_io_stop(EV_DEFAULT, &(listener->io)); 
		};
		
		struct req_state *state = alloc_state();
		
		if(!state){
			warn("HTTP::Server::EV ERROR: Can`t allocate memory for connection state. Connection dropped!");
			close(accepted_socket);
			return;
		}
		
		state->parent_listener = listener;
		state->timeout = listener->timeout;
		
		hv_store(state->headers, "REMOTE_ADDR" , 11 , newSVpv(inet_ntoa( cliaddr.sin_addr ), 0 ) , 0);
		hv_store(state->rethash, "fd", 2, newSViv(accepted_socket), 0);
		
		
		ev_io_init (&state->io, handler_cb, accepted_socket , EV_READ);
		ev_io_start ( loop, &state->io);
		
		
		if (state->timeout != 0) {
			ev_timer_init(&state->timer, timer_cb, 0., listener->timeout);
			state->timer.data = (void *) state;
			
			ev_timer_again(loop, &(state->timer));
		}
}





MODULE = HTTP::Server::EV	PACKAGE = HTTP::Server::EV	

PROTOTYPES: DISABLE

BOOT:
{
	I_EV_API ("HTTP::Server::EV");
#ifdef WIN32
	_setmaxstdio(2048); 
#endif
}


SV*
listen_socket ( sock ,callback, pre_callback, error_callback, timeout)
	int sock
	SV* callback
	SV* pre_callback
	SV* error_callback
	float timeout
	CODE:
		SvREFCNT_inc(callback);
		SvREFCNT_inc(pre_callback);
		SvREFCNT_inc(error_callback);
		
		
		
		
		struct port_listener* listener = (struct port_listener *) malloc(sizeof(struct port_listener));
		
		listener->callback = callback;
		listener->pre_callback = pre_callback;
		listener->error_callback = error_callback;
		listener->timeout = timeout;
		
		ev_io_init(&(listener->io), listen_cb, sock, EV_READ);
		ev_io_start(EV_DEFAULT, &(listener->io));
		
		SV* magic_sv = newSViv( (int) &(listener->io));
		sv_magicext (magic_sv , 0, PERL_MAGIC_ext, NULL, (const char *) &(listener->io), 0);
		RETVAL = magic_sv;
	OUTPUT:
		RETVAL
	
void
stop_listen (self)	
	SV* self
	CODE:
		MAGIC *mg ;
		for (mg = SvMAGIC (self); mg; mg = mg->mg_moremagic) {
			if (mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == NULL){
				ev_io_stop(EV_DEFAULT, (ev_io *) mg->mg_ptr); 
				break;
			}	
		}
		

void
start_listen ( self )	
		SV* self
	CODE:
		MAGIC *mg ;
		for (mg = SvMAGIC (self); mg; mg = mg->mg_moremagic) {
			if (mg->mg_type == PERL_MAGIC_ext && mg->mg_virtual == NULL){
				ev_io_start(EV_DEFAULT, (ev_io *) mg->mg_ptr); 	
				break;
			}	
		}
		

void
stop_req( saved_to )	
	int saved_to
	CODE:
		struct req_state *state = accepted[saved_to];
		state->reading |= 1 << 7; // 7 bit set - suspended
		
		if (state->timeout != 0.) ev_timer_stop(EV_DEFAULT, &state->timer);
		ev_io_stop(EV_DEFAULT, &(state->io)); 
		

SV*
start_req( saved_to )	
	int saved_to
	CODE:
		struct req_state *state = accepted[saved_to];
		
		state->reading &= ~(1 << 7); // 7 bit null - working
		ev_io_start(EV_DEFAULT, &(state->io)); 
		if (state->timeout != 0.) ev_timer_again(EV_DEFAULT, &state->timer);
		
		// if(state->buffer_pos)
		// ev_feed_fd_event(EV_DEFAULT, &(state->io), 0);
		// No ev_feed_fd_event in EV XS API :(
		// Pass fd and do it from perl
		
		RETVAL = state->buffer_pos ? newSViv(state->io.fd) : newSV(0);
		
		
	OUTPUT:
        RETVAL
		
void
drop_req( saved_to )	
	int saved_to
	CODE:
		accepted[saved_to]->reading = REQ_DROPED_BY_PERL;
		ev_io_start(EV_DEFAULT, &(accepted[saved_to]->io)); 
	
	
	
#define URLDECODE_READ_CHAR 2
#define URLDECODE_READ_FIRST_PART 3
#define URLDECODE_READ_SECOND_PART 4

void
url_decode( encoded )	
	SV* encoded
	PPCODE:
		SV* output = newSV( 100 );
		
		STRLEN len;
			
		char *input = SvPV(encoded, len);
		
		char state = URLDECODE_READ_CHAR;
		
		char byte = (char)NULL;
		int pos = 0;
		for(; pos < len ; pos++){
			if( input[pos] == '%' ){
				state = URLDECODE_READ_FIRST_PART;
				byte = (char)NULL;
			}else
			if(state == URLDECODE_READ_CHAR){
				sv_catpvn(output, input+pos, 1);
			}else{
				if(state == URLDECODE_READ_FIRST_PART){
					byte = (isdigit(input[pos]) ? input[pos] - '0' : tolower(input[pos]) - 'a' + 10) << 4;
					state = URLDECODE_READ_SECOND_PART;
				}else{ // state == URLDECODE_READ_SECOND_PART
					byte |= (isdigit(input[pos]) ? input[pos] - '0' : tolower(input[pos]) - 'a' + 10);
					sv_catpvn(output, &byte, 1);
					byte = (char)NULL;
					state = URLDECODE_READ_CHAR;
				}
			}
		};
		
		STRLEN out_len;
		char *out_ptr = SvPV(output, out_len);
		
		XPUSHs(sv_2mortal(output));
		XPUSHs(sv_2mortal(newSViv( is_utf8_string( out_ptr , out_len) )));

		