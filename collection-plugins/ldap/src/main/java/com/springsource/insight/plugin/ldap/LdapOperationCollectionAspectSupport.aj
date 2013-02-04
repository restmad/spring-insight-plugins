/**
 * Copyright (c) 2009-2011 VMware, Inc. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.springsource.insight.plugin.ldap;

import java.io.Serializable;
import java.util.Collection;
import java.util.Collections;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.logging.Level;

import javax.naming.Context;
import javax.naming.NamingException;

import org.aspectj.lang.JoinPoint;
import org.aspectj.lang.Signature;
import org.aspectj.lang.annotation.SuppressAjWarnings;
import org.aspectj.lang.reflect.CodeSignature;
import org.aspectj.lang.reflect.MethodSignature;

import com.springsource.insight.collection.FrameBuilderHintObscuredValueMarker;
import com.springsource.insight.collection.OperationCollectionAspectSupport;
import com.springsource.insight.collection.OperationCollector;
import com.springsource.insight.intercept.InterceptConfiguration;
import com.springsource.insight.intercept.operation.Operation;
import com.springsource.insight.intercept.operation.OperationFields;
import com.springsource.insight.intercept.operation.OperationMap;
import com.springsource.insight.intercept.operation.SourceCodeLocation;
import com.springsource.insight.intercept.operation.method.JoinPointBreakDown;
import com.springsource.insight.intercept.plugin.CollectionSettingName;
import com.springsource.insight.intercept.plugin.CollectionSettingsRegistry;
import com.springsource.insight.intercept.plugin.CollectionSettingsUpdateListener;
import com.springsource.insight.intercept.trace.FrameBuilder;
import com.springsource.insight.intercept.trace.ObscuredValueMarker;
import com.springsource.insight.util.StringFormatterUtils;
import com.springsource.insight.util.StringUtil;
import com.springsource.insight.util.logging.InsightLogManager;

/**
 * 
 */
public abstract aspect LdapOperationCollectionAspectSupport
        extends OperationCollectionAspectSupport {
    /**
     * Default logging {@link Level} for tracker
     */
    public static final Level  DEFAULT_LEVEL=Level.OFF;
    private static volatile Level  logLevel=DEFAULT_LEVEL;
    static final Class<?>[]   EMPTY_PARAMS={ };

    protected final Class<? extends Context> contextClass;
    protected final String  action;
    protected ObscuredValueMarker obscuredMarker =
            new FrameBuilderHintObscuredValueMarker(configuration.getFrameBuilder());

    protected static final InterceptConfiguration configuration = InterceptConfiguration.getInstance();
    protected static final CollectionSettingName    OBFUSCATED_PROPERTIES_SETTING =
            new CollectionSettingName("obfuscated.properties", LdapPluginRuntimeDescriptor.PLUGIN_NAME, "Comma separated list of context properties whose data requires obfuscation");
    protected static final CollectionSettingName    LDAP_OPERATIONS_LOG_SETTING =
            new CollectionSettingName("tracking.loglevel", LdapPluginRuntimeDescriptor.PLUGIN_NAME, "The java.util.logging.Level value to use for logging internal functionality (default=" + DEFAULT_LEVEL + ")");

    // NOTE: using a synchronized set in order to allow modification while running
    static final Set<String>    OBFUSCATED_PROPERTIES=
            Collections.synchronizedSet(new TreeSet<String>(String.CASE_INSENSITIVE_ORDER));
    public static final String DEFAULT_OBFUSCATED_PROPERTIES_LIST=
            Context.SECURITY_PRINCIPAL + "," + Context.SECURITY_CREDENTIALS;

    // register a collection setting update listener to update the obfuscated properties
    static {
        CollectionSettingsRegistry registry = CollectionSettingsRegistry.getInstance();
        registry.addListener(new CollectionSettingsUpdateListener() {
                @SuppressWarnings("synthetic-access")
                public void incrementalUpdate (CollectionSettingName name, Serializable value) {
                    if (OBFUSCATED_PROPERTIES_SETTING.equals(name) && (value instanceof String)) {
                       Collection<String>	newNames=StringUtil.explode((String) value, ",");
                       if ((newNames.size() != OBFUSCATED_PROPERTIES.size())
                    	|| (!OBFUSCATED_PROPERTIES.containsAll(newNames))) {
                    	   InsightLogManager.getLogger(LdapOperationCollectionAspectSupport.class.getName())
   	   										.info("incrementalUpdate(" + name + ")" + OBFUSCATED_PROPERTIES + " => [" + value + "]")
   	   										;
                    	   OBFUSCATED_PROPERTIES.clear();
                    	   OBFUSCATED_PROPERTIES.addAll(newNames);
                       }
                    } else if (LDAP_OPERATIONS_LOG_SETTING.equals(name)) {
                        Level newValue=CollectionSettingsRegistry.getLogLevelSetting(value);
                        if (newValue != logLevel) {
                        	InsightLogManager.getLogger(LdapOperationCollectionAspectSupport.class.getName())
                        					 .info("incrementalUpdate(" + name + ") " + logLevel + " => " + newValue)
                        					 ;
                        	logLevel = newValue;
                        }
                    }
                }
            });
        registry.register(LDAP_OPERATIONS_LOG_SETTING, DEFAULT_LEVEL);
        // NOTE: this also populates the initial set
        registry.register(OBFUSCATED_PROPERTIES_SETTING, DEFAULT_OBFUSCATED_PROPERTIES_LIST);
    }

    protected LdapOperationCollectionAspectSupport (Class<? extends Context> ldapContextClass, String ldapAction) {
        contextClass = ldapContextClass;
        action = ldapAction;
    }

    void setSensitiveValueMarker(ObscuredValueMarker marker) {
        this.obscuredMarker = marker;
    }

    public abstract pointcut collectionPoint();

    @SuppressAjWarnings({"adviceDidNotMatch"})
    Object around () throws NamingException
        : collectionPoint() && if(strategies.collect(thisAspectInstance,thisJoinPointStaticPart)) {
        Operation           op=createOperation(thisJoinPoint);
        OperationCollector  collector=(op == null) ? null : getCollector();
        if (collector != null) {
            collector.enter(op);
        }
        
        try {
            Object  returnValue=proceed();
            if (collector != null) {
                if (((MethodSignature) thisJoinPointStaticPart.getSignature()).getReturnType() == void.class) {
                    collector.exitNormal();
                } else {
                    collector.exitNormal(returnValue);
                }
            }
            
            return returnValue;
        } catch(NamingException e) {
            if (collector != null) {
                collector.exitAbnormal(e);
            }
            
            throw e;
        }
    }

    /**
     * @param jp The current {@link JoinPoint}
     * @return An initial {@link Operation} - <code>null</code> if not an LDAP call
     */
    protected Operation createOperation(JoinPoint jp) {
        Context     context=(Context) jp.getTarget();
        Map<?,?>    environment;
        try {
            environment = context.getEnvironment();
        } catch(NamingException e) {
            if (isLoggingEnabled()) {
                log("Failed (" + e.getClass().getSimpleName() + ") to get environment: " + e.getMessage(), e);
            }
            
            return null;
        }

        String  url=(String) environment.get(Context.PROVIDER_URL);
        if (StringUtil.isEmpty(url) || (!url.startsWith("ldap://"))) {
            return null;
        }

        Signature           sig=jp.getSignature();
        SourceCodeLocation  loc=getSourceCodeLocation(jp);
        Class<?>[]          params=(sig instanceof CodeSignature) ? ((CodeSignature) sig).getParameterTypes() : EMPTY_PARAMS;
        Operation           op=new Operation()
                                .type(LdapDefinitions.LDAP_OP)
                                .label("LDAP " + action)
                                .sourceCodeLocation(loc)
                                .put(OperationFields.CONNECTION_URL, url)
                                // see OperationCache#makeOperationTemplate
                                .put(OperationFields.CLASS_NAME, contextClass.getName())
                                .put(OperationFields.SHORT_CLASS_NAME, contextClass.getSimpleName())
                                .put(OperationFields.METHOD_SIGNATURE, JoinPointBreakDown.getMethodStringFromArgs(loc, params))
                                .put(OperationFields.METHOD_NAME, action)
                                .put(LdapDefinitions.LOOKUP_NAME_ATTR, LdapDefinitions.getNameValue(jp.getArgs()))
                                ;
        if (collectExtraInformation()) {
            extractContextEnvironment(op.createMap("environment"), environment);
        }

        return op;
    }

    boolean collectExtraInformation ()
    {
        return FrameBuilder.OperationCollectionLevel.HIGH.equals(configuration.getCollectionLevel());
    }

    boolean isLoggingEnabled () {
        return (logLevel != null) && (!Level.OFF.equals(logLevel)) && _logger.isLoggable(logLevel);
    }

    String log (String msg) {
        return log(msg, null);
    }

    String log (String msg, Throwable thrown) {
        if (thrown == null) {
            _logger.log(logLevel, msg);
        } else {
            _logger.log(logLevel, msg, thrown);
        }
        
        return msg;
    }

    OperationMap extractContextEnvironment (OperationMap op, Map<?,?> environment) {
        for (Map.Entry<?,?> vp : environment.entrySet()) {
            String  name=(String) vp.getKey();
            Object  value=vp.getValue();
            String  strValue=StringFormatterUtils.formatObjectAndTrim(value);
            if (OBFUSCATED_PROPERTIES.contains(name)) {
                obscuredMarker.markObscured(value);
                obscuredMarker.markObscured(strValue);  // don't take any chances...
            }
            op.put(name, strValue);
        }
        
        return op;
    }

    static final <T> T findLastArgument (Class<T> expectedClass, Object... args) {
        for (int    index=args.length-1; index >= 0; index--) {
            Object      arg=args[index];
            Class<?>    argClass=(arg == null) ? null : arg.getClass();
            if ((argClass != null) & expectedClass.isAssignableFrom(argClass)) {
                return expectedClass.cast(arg);
            }
        }
        
        return null;
    }

    @Override
    public String getPluginName() { return LdapPluginRuntimeDescriptor.PLUGIN_NAME; }
    
    @Override
    public boolean isMetricsGenerator() {
        return true; // This provides an external resource
    }
}
