#ifndef __CON4M_H__
#define __CON4M_H__

#include <stdint.h>

typedef void *C4State;
typedef void *C4Spec;
typedef void *NimDict;
typedef void *Box;
typedef Box  *BoxArray;
// BoxUnused forces 64-bit ints.
typedef enum {
    BoxInt,
    BoxStr,
    BoxFloat,
    BoxSeq,
    BoxBool,
    BoxTable,
    BoxObj,
    BoxUnused = 0x7fffffffffffffff
} BoxType;
typedef enum {
    ErrAttrOk,
    ErrNoAttr,
    ErrBadSec,
    ErrBadAttr,
    ErrCantSet,
    ErrAttrUnused = 0x7fffffffffffffff
} AttrErr;

// Call this to initialize the garbage collector.
extern void NimMain();

/* char *c4mOneShot(char *, char *)
 *
 * This call will run con4m once.  The first parameter is the code to
 * run, and the second parameter is the file name for reporting.  The
 * return value is either a JSON object consisting of the attribute
 * state after evaluation, or a single string containing a printable
 * error message.
 */

extern char *c4mOneShot(char *, char *);
/* C4State c4mFirstRun(char *, char *, int64_t, C4Spec, char **);
 *
 * When not using the one-shot API, you should call this to run Con4m
 * the first time.
 * - The first parameter is the con4m source code.
 * - The second is the file name, which is used for error messages.
 * - The third parameter controls whether the built-in functions are
 *   installed. Currently, we're not exposing the ability to selectively
 *   remove builtins, nor are we exposing the ability to add your own.
 * - The fourth parameter is a C4Spec object, which is optional. This is
 *   used to do validation on a con4m file. From this API, there's no
 *   way to create a spec programatically, but you can load one from a
 *   con4m file (using the c42nim schema).
 *   See c4mLoadSpec() below.
 * - The final parameter points to an error message, if there is one.
 *   This will otherwise be NULL when there's no error (the return
 *   value is NULL when there *is* an error).
 *
 * Note that Nim controls the memory of the return value, so free it
 * with c4mStateDelete().  Similarly, any error message needs to be
 * freed.
 */
extern C4State c4mFirstRun(char *, char *, int64_t, C4Spec, char **);

/* char *c4mStack(C4State, char *, char *, C4Spec);
 *
 * After the first run, you can use this call to stack more config
 * exections on top of the same state.
 *
 * - The first parameter is an existing state object, as received from
 *   a call to c4mFirstRun
 * - The second parameter is the con4m source.
 * - The third parameter is the file name for error messages.
 * - The fourth parameter is the spec state if you're doing validation.
 *
 * The return will be NULL if successful. Otherwise, it will be an error
 * message, which needs to be deleted via c4mStrDelete() when done.
 */
extern char *c4mStack(C4State, char *, char *, C4Spec); // If err, decref.

/* int64_t c4mGetAttrInt(C4State, char *, AttrErr *);
 *
 * Returns the value of an attribute field that is an int field.
 * If you're using a C4Spec, you can be guaranteed that your declared
 * types will be honored. Otherwise, use c4mGetAttr(), which will give
 * you a Box object, and tell you the base type of the box.
 *
 * If you're wrong about the type, you should get a sweet crash :)
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 will receive an error code of type AttrErr, defined above.
 */
extern int64_t c4mGetAttrInt(C4State, char *, AttrErr *);

/* int64_t c4mGetAttrBool(C4State, char *, AttrErr *);
 *
 * Returns the value of an attribute field that is a bool field.
 * If you're using a C4Spec, you can be guaranteed that your declared
 * types will be honored. Otherwise, use c4mGetAttr(), which will give
 * you a Box object, and tell you the base type of the box.
 *
 * The bool val is cast to an int64_t, but should always be 0 or 1.
 *
 * If you're wrong about the type, you should get a sweet crash :)
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 will receive an error code of type AttrErr, defined above.
 */
extern int64_t c4mGetAttrBool(C4State, char *, AttrErr *);

/* char *c4mGetAttrStr(C4State, char *, AttrErr *);
 *
 * Returns the value of an attribute field that is a con4m string field.
 * If you're using a C4Spec, you can be guaranteed that your declared
 * types will be honored. Otherwise, use c4mGetAttr(), which will give
 * you a Box object, and tell you the base type of the box.
 *
 * If you're wrong about the type, you should get a sweet crash :)
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 will receive an error code of type AttrErr, defined above.
 */
extern char *c4mGetAttrStr(C4State, char *, AttrErr *);

/* float c4mGetAttrFloat(C4State, char *, AttrErr *);
 *
 * Returns the value of an attribute field that is a con4m float field.
 * If you're using a C4Spec, you can be guaranteed that your declared
 * types will be honored. Otherwise, use c4mGetAttr(), which will give
 * you a Box object, and tell you the base type of the box.
 *
 * If you're wrong about the type, you should get a sweet crash :)
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 will receive an error code of type AttrErr, defined above.
 */
extern float c4mGetAttrFloat(C4State, char *, AttrErr *);

/* Box c4mGetAttr(C4State, char *, BoxType *, AttrErr *);
 *
 * Returns the value of an attribute field, as a Con4m Box object.
 * The Box object is owned by the Nim runtime, so needs to be
 * explicitly deallocated (really, decref'd -- if you get the same
 * result 3 times, we incref it 3 times). Note that the "unpack"
 * operations will automatically do the decref, or you can call
 * c4mBoxDelete().
 *
 * For values that are primitive types, if you're using the spec, you
 * can just use the calls that skip straight to the primitive type.
 * For arrays and tables, since they can be nested, you need to
 * decompose the items individually.
 *
 * Note that tuple types in Con4m are going to be accessed as an array
 * of boxed items. From this API's perspective, the only difference
 * between a con4m array and a con4m tuple is that the boxes of arrays
 * are all guaranteed to be of the same type.
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 will receive the type of the box returned, but only the
 *           top-level type for containers; if you don't know the type
 *           you will need to query the individual boxes as you
 *           decompose.
 * - Param 4 will receive an error code of type AttrErr, defined above.
 */
extern Box c4mGetAttr(C4State, char *, BoxType *, AttrErr *);

/* AttrErr c4mSetAttrInt(C4State, char *, int64_t);
 *
 * Sets a Con4m attribute field with an int value.
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 is the value to set.
 *
 * If you are not using the spec functionality, any setting
 * you do still needs to be type compatible with what is already
 * there, or you will get an error returned.
 */
extern AttrErr c4mSetAttrInt(C4State, char *, int64_t);

/* AttrErr c4mSetAttrBool(C4State, char *, int64_t);
 *
 * Sets a Con4m attribute field with a bool value (passed as an int64_t)
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 is the value to set, 0 is false, anything else is true.
 *
 * If you are not using the spec functionality, any setting
 * you do still needs to be type compatible with what is already
 * there, or you will get an error returned.
 */
extern AttrErr c4mSetAttrBool(C4State, char *, int64_t);

/* AttrErr c4mSetAttrInt(C4State, char *, int64_t);
 *
 * Sets a Con4m attribute field with an int value.
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 is the value to set.
 *
 * If you are not using the spec functionality, any setting
 * you do still needs to be type compatible with what is already
 * there, or you will get an error returned.
 */
extern AttrErr c4mSetAttrStr(C4State, char *, char *);

/* AttrErr c4mSetAttrInt(C4State, char *, float);
 *
 * Sets a Con4m attribute field with an float value.
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 is the value to set.
 *
 * If you are not using the spec functionality, any setting
 * you do still needs to be type compatible with what is already
 * there, or you will get an error returned.
 */
extern AttrErr c4mSetAttrFloat(C4State, char *, float);

/* AttrErr c4mSetAttr(C4State, char *, Box);
 *
 * Sets a Con4m attribute field with an int value.
 *
 * - Param 1 is the configuration state object.
 * - Param 2 is the fully dotted name to query.
 * - Param 3 is the value to set. This value must be a valid
 *   Con4m Box; see the c4mPack* calls.
 *
 * If you are not using the spec functionality, any setting
 * you do still needs to be type compatible with what is already
 * there, or you will get an error returned.
 *
 * From a memory management perspective, this call has no impact
 * (i.e., it neither increfs or decrefs).
 */
extern AttrErr c4mSetAttr(C4State, char *, Box);

/* BoxType c4mBoxType(Box);
 *
 * Returns the outmost type of a box.
 */
extern BoxType c4mBoxType(Box);

/* int64_t c4mUnpackInt(Box)
 *
 * Returns the value inside an integer box. You still need to decred
 * the box if you're done with it.
 *
 * If the box doesn't represent an int, you'll end up with a crash.
 */
extern int64_t c4mUnpackInt(Box);

/* int64_t c4mUnpackBool(Box)
 *
 * Returns the value inside a bool box. You still need to decred
 * the box if you're done with it.  Returns it as a 64-bit int but
 * will always be 0 or 1.
 *
 * If the box doesn't represent a bool, you'll end up with a crash.
 */
extern int64_t c4mUnpackInt(Box);

/* float c4mUnpackFloat(Box)
 *
 * Returns the value inside a float box. You still need to decref the
 * box if you're done with it.
 *
 * If the box doesn't represent a float, you'll end up with a crash.
 */
extern float c4mUnpackFloat(Box);

/* char *c4mUnpackString(Box)
 *
 * Returns the value inside a string box. You still need to decref the
 * box if you're done with it.
 *
 * If the box doesn't represent a string, you'll end up with a crash.
 */
extern char *c4mUnpackString(Box);

/* int64_t  c4mUnpackArray(Box, BoxArray *);
 *
 * Decomposes the box passed in the first argument into an array of boxes.
 * The second argument will get a pointer to the box array, and the
 * number of items in the box will be returned.
 *
 * This increfs the returned array. The Box items are *not* seprately
 * incref'd and do not need to be decref'd. However, you should not
 * hold on to any of the boxes in the array after the array itself is
 * deallocated.
 *
 * Use c4mArrayDelete() to dealloc the outter array.
 */
extern int64_t  c4mUnpackArray(Box, BoxArray *);
extern BoxArray c4mUnpackArray2(Box, int64_t *);

/* NimDict c4mUnpackDict(Box);
 *
 * Unpacks a boxed NimDict, and decref's the box.
 */
extern NimDict c4mUnpackDict(Box); // Input is decref'd, output incref'd

/* Box c4mPackArray(Box *, int64_t);
 *
 * Packs an array into a Box. This will copy the box objects, so your
 * array can be freed when this call returns. The result is incref'd
 * and will need to be decref'd.
 */
extern Box c4mPackString(char *);
extern Box c4mPackFloat(float);
extern Box c4mPackInt(int64_t);
extern Box c4mPackBool(int64_t);
extern Box c4mPackArray(Box *, int64_t);

/* NimDict c4mDictNew();
 *
 * Creates a new NimDict object.  It will need deallocation.
 */
extern NimDict c4mDictNew();
/* Box c4mDictLookup(NimDict, Box);
 *
 * Lookup a dictionary item based on a pre-boxed key. The result is
 * incref'd, and needs to be decref'd (e.g., by unboxing), when done.
 */
extern Box c4mDictLookup(NimDict, Box);

/* void c4mDictSet(NimDict, Box, Box);
 *
 * Set a value (3rd arg arg) associated w/ a key (2nd arg) in a
 * NimDict (1st arg).  Both the key and the value should be pre-boxed.
 */
extern void c4mDictSet(NimDict, Box, Box);

/* void c4mDictKeyDel(NimDict, Box);
 *
 * Deletes a key-value pair specified by a key, if they key is
 * present.
 */
extern void c4mDictKeyDel(NimDict, Box);

/* C4Spec c4mLoadSpec(char *, char *, int64_t *);
 *
 * Loads a c42spec file.  The first argument is a string with the
 * con4m source code. The second is the file name for purposes of
 * error reporting.
 *
 * The third gets a non-zero value on success, or zero on failure.  If
 * there's a failure, the error can be retrieved with c4mGetSpecErr().
 *
 * The spec object is otherwise opaque, to be passed in when
 * evaluating configs.
 */
extern C4Spec c4mLoadSpec(char *, char *, int64_t *);

/* int64_t  c4mGetSections(C4State, char *, char ***);
 *
 * Given a fully-qualified path to a section, produces an array
 * containing the names of all defined sections.  The return value is
 * the number of items in the array.
 *
 * - The first param is the spec object.
 * - The second param is the dotted path to the section.  The root is just
     the empty string.
 * - The third array is a pointer to a char**. Nim will set this, and own
     the memory, so call c4mArrayDelete() to dealloc.
 *
 * The return value is the number of items in the array that is passed back.
 */
extern int64_t c4mGetSections(C4State, char *, char ***);

/* int64_t  c4mGetFields(C4State, char *, char ***);
 *
 * Given a fully-qualified path to a section, produces an array
 * containing the names of all defined fields in that section,
 * followed by their Con4m type as a string.
 *
 * The return value is the number of total items in the array,
 * including the type specs.
 *
 * - The first param is the spec object.
 * - The second param is the dotted path to the section.  The root is just
     the empty string.
 * - The third array is a pointer to a char**. Nim will set this, and own
     the memory, so call c4mArrayDelete() to dealloc.
 *
 * The return value is the number of items in the array that is passed back.
 */
extern int64_t c4mGetFields(C4State, char *, char ***);

/* int64_t  c4mEnumerateScope(C4State, char *, char ***);
 *
 * Given a fully-qualified path to a section, produces an array
 * containing the names of all defined fields in that section,
 * followed by their Con4m type as a string, or in the case of
 * sections, the word "section".
 *
 * The return value is the number of total items in the array,
 * including the type specs.
 *
 * - The first param is the spec object.
 * - The second param is the dotted path to the section.  The root is just
     the empty string.
 * - The third array is a pointer to a char**. Nim will set this, and own
     the memory, so call c4mArrayDelete() to dealloc.
 *
 * The return value is the number of items in the array that is passed back.
 */
extern int64_t c4mEnumerateScope(C4State, char *, char ***);
// Below are all deallocation functions.
extern void  c4mClose(C4State);
extern char *c4mGetSpecErr(C4Spec);
extern void  c4mSpecDelete(C4Spec);
extern void  c4mDictDelete(NimDict);
extern void  c4mStrDelete(char *);
extern void  c4mArrayDelete(BoxArray);
extern void  c4mStateDelete(C4State);
extern void  c4mBoxDelete(Box);

#endif
